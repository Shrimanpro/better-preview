import AppKit
import BPCore
import PDFKit

/// The PDF viewer: a PDFView plus vim-style navigation, smooth scrolling,
/// sticky fit modes, search and recolor. Feature areas live
/// in extensions: `+Navigation`, `+Zoom`, `+Search`, `+Appearance`, `+Outline`.
@MainActor
final class PDFDocumentController: NSObject, DocumentController {
    let fileURL: URL
    weak var host: DocumentHost?
    let changes = ChangeTrackingUndoManager()
    var undoManager: UndoManager { changes }
    /// Set to true by editing features (markup, pages, forms) after a change;
    /// false once the document is back at its saved state (undo included).
    var isDirty: Bool {
        get { changes.hasUnsavedChanges }
        set { newValue ? changes.noteChange() : changes.markSaved() }
    }

    let pdfView = BPPDFView()
    private(set) lazy var scroller = SmoothScroller(host: pdfView)
    /// Recolours PDFKit's white paper behind unrendered tiles (recolor only).
    private(set) lazy var tileBackdrop = TileBackdrop(pdfView: pdfView)
    let search = PDFSearch()
    /// Recolor parameters read by the pages while they draw.
    let renderState = PageRenderState()
    /// The password the file was opened with (encrypted PDFs); saving keeps it.
    var documentPassword: String?
    /// Direction of the last `/` or `?`; `n` follows it, `N` reverses it.
    /// Set by the window layer when it opens the search bar.
    var searchDirectionBackward = false

    /// Applied configuration, diffed by `apply(options:theme:)`.
    private(set) var options = Options()
    private(set) var theme: Theme?
    private var hasAppliedOptions = false

    // Layout state. Toggles override the options until the option changes.
    var fitMode: FitMode = .width
    var isContinuous = true
    var isDual = false
    var isRecolored = false
    /// View-only rotation added to every page, in degrees (0, 90, 180, 270).
    /// Removed again while saving so it never reaches the file.
    var viewRotation = 0
    /// True while this controller changes the scale, so PDFViewScaleChanged
    /// can tell programmatic zoom from pinch zoom.
    var isSettingScale = false
    private(set) var hasInitialLayout = false
    /// Navigation that arrived before the first layout, replayed after it.
    private var pendingNavigation: [() -> Void] = []

    /// Runs `body` now if the first layout happened, else right after it.
    /// Returns true if it was deferred.
    @discardableResult
    func deferUntilLaidOut(_ body: @escaping () -> Void) -> Bool {
        guard !hasInitialLayout else {
            body()
            return false
        }
        pendingNavigation.append(body)
        return true
    }

    /// Editing features, each living in its own directory.
    private(set) lazy var features: [PDFFeature] = []

    private var statusUpdateScheduled = false
    var isObservingScroll = false
    private var lastReportedStatus: DocumentStatus?
    private var lastReportedDirty = false

    init?(url: URL) {
        guard let opened = BPDocument.openUnlocking(url: url, renderState: renderState),
              opened.document.pageCount > 0 else {
            return nil
        }
        let document = opened.document
        fileURL = url
        super.init()
        documentPassword = opened.password
        changes.onChange = { [weak self] in MainActor.assumeIsolated { self?.scheduleStatusUpdate() } }
        PDFKitTuning.applyAnalysis(AppEnvironment.shared.options.pdfkitAnalysis, to: pdfView)
        pdfView.autoScales = false
        pdfView.pageShadowsEnabled = false
        pdfView.displaysPageBreaks = true
        pdfView.displayDirection = .vertical
        pdfView.document = document
        updateDisplayMode()
        applyPagePadding()
        pdfView.onResize = { [weak self] in self?.viewDidResize() }
        pdfView.mouseHandler = { [weak self] event in
            self?.features.contains { $0.handleMouse(event) } ?? false
        }
        search.controller = self

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(pageChanged),
                           name: .PDFViewPageChanged, object: pdfView)
        center.addObserver(self, selector: #selector(scaleChanged),
                           name: .PDFViewScaleChanged, object: pdfView)
    }

    var view: NSView { pdfView }
    var preferredFirstResponder: NSView { pdfView }
    var document: PDFDocument? { pdfView.document }

    // MARK: Status

    var status: DocumentStatus {
        var s = DocumentStatus()
        if let document {
            s.page = currentPageIndex + 1
            s.pageCount = document.pageCount
        }
        s.zoom = pdfView.scaleFactor
        s.position = scrollPercentage
        if isDual { s.flags.append("dual") }
        if !isContinuous { s.flags.append("single") }
        if isRecolored { s.flags.append("recolor") }
        for feature in features { s.flags += feature.statusFlags }
        s.detail = search.statusDetail
        return s
    }

    var currentPageIndex: Int {
        guard let document, let page = pdfView.currentPage else { return 0 }
        return document.index(for: page)
    }

    /// Notifies the host at most once per run-loop turn, and only if
    /// something it shows actually changed.
    func scheduleStatusUpdate() {
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusUpdateScheduled = false
            let s = status
            guard s != lastReportedStatus || isDirty != lastReportedDirty else { return }
            lastReportedStatus = s
            lastReportedDirty = isDirty
            host?.documentStatusDidChange()
        }
    }

    @objc private func pageChanged() {
        refreshSearchHighlights()
        scheduleStatusUpdate()
    }

    @objc private func scaleChanged() {
        if !isSettingScale {
            // Pinch or smart zoom: an explicit zoom ends the fit mode.
            scroller.stop()
            fitMode = .none
        }
        scheduleStatusUpdate()
    }

    // MARK: Actions

    /// Actions that need the first layout (a real viewport and scale).
    private static let layoutDependent: Set<ActionName> = [
        .scrollDown, .scrollUp, .scrollRight, .scrollLeft, .scrollHalfDown, .scrollHalfUp,
        .scrollPageDown, .scrollPageUp, .pageNext, .pagePrevious, .gotoFirst, .gotoLast, .gotoPage,
        .zoomIn, .zoomOut, .zoomReset, .zoomSet, .fitPage, .fitWidth,
    ]

    @discardableResult
    func perform(_ invocation: ActionInvocation) -> Bool {
        // Keys pressed before the window's first layout would be undone by
        // it (it fits and shows the top of page 1): run them right after.
        if !hasInitialLayout, Self.layoutDependent.contains(invocation.action.name) {
            deferUntilLaidOut { [weak self] in self?.perform(invocation) }
            return true
        }
        let n = max(1, invocation.count ?? 1)
        let argument = invocation.action.argument
        switch invocation.action.name {
        case .scrollDown: scroll(viewDX: 0, viewDY: options.scrollStep * Double(n))
        case .scrollUp: scroll(viewDX: 0, viewDY: -options.scrollStep * Double(n))
        case .scrollRight: scroll(viewDX: options.scrollHStep * Double(n), viewDY: 0)
        case .scrollLeft: scroll(viewDX: -options.scrollHStep * Double(n), viewDY: 0)
        case .scrollHalfDown: scroll(screens: 0.5 * Double(n))
        case .scrollHalfUp: scroll(screens: -0.5 * Double(n))
        case .scrollPageDown: scroll(screens: (1 - options.scrollPageOverlap) * Double(n))
        case .scrollPageUp: scroll(screens: -(1 - options.scrollPageOverlap) * Double(n))
        case .pageNext: goToAdjacentPage(by: n)
        case .pagePrevious: goToAdjacentPage(by: -n)
        case .gotoFirst: invocation.count.map { goToPage(number: $0) } ?? goToDocumentEdge(end: false)
        case .gotoLast: invocation.count.map { goToPage(number: $0) } ?? goToDocumentEdge(end: true)
        case .gotoPage:
            guard let number = argument.flatMap({ Int($0.trimmingCharacters(in: .whitespaces)) })
                    ?? invocation.count else { return false }
            goToPage(number: number)

        case .zoomIn: zoom(by: pow(options.zoomStep, Double(n)))
        case .zoomOut: zoom(by: pow(options.zoomStep, -Double(n)))
        case .zoomReset: setScale(1)
        case .zoomSet:
            let text = (argument ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " %"))
            guard let percent = Double(text), percent > 0 else { return false }
            setScale(percent / 100)
        case .fitPage: fit(.page)
        case .fitWidth: fit(.width)
        case .rotateCW: rotateView(by: 90)
        case .rotateCCW: rotateView(by: -90)
        case .toggleDualPage:
            isDual.toggle()
            layoutDidChange()
        case .toggleContinuous:
            isContinuous.toggle()
            layoutDidChange()
        case .toggleRecolor:
            isRecolored.toggle()
            updateRecolor()

        case .searchRun: runSearch(argument ?? "")
        case .searchNext: stepSearch(by: n, reverse: false)
        case .searchPrevious: stepSearch(by: n, reverse: true)
        case .searchClear: clearSearch()

        case .copy: pdfView.copy(nil)
        case .selectAll: pdfView.selectAll(nil)
        case .reload: reloadFromDisk()
        // M2: marks and the jump list (window layer) use currentPosition/go(to:).
        case .markSet, .markJump, .jumpBack, .jumpForward: return false
        default: return features.contains { $0.handle(invocation) }
        }
        return true
    }

    // MARK: Configuration

    func apply(options new: Options, theme newTheme: Theme) {
        let old = options
        let first = !hasAppliedOptions
        hasAppliedOptions = true
        options = new

        scroller.isEnabled = new.smoothScroll
        if first || old.pdfkitAnalysis != new.pdfkitAnalysis {
            PDFKitTuning.applyAnalysis(new.pdfkitAnalysis, to: pdfView)
        }
        scroller.settleDuration = new.scrollDuration
        if first || old.zoomMin != new.zoomMin || old.zoomMax != new.zoomMax {
            pdfView.minScaleFactor = new.zoomMin
            pdfView.maxScaleFactor = new.zoomMax
        }
        var layoutChanged = false
        if first || old.continuous != new.continuous {
            isContinuous = new.continuous
            layoutChanged = true
        }
        if first || old.dualPage != new.dualPage {
            isDual = new.dualPage
            layoutChanged = true
        }
        if first || old.recolor != new.recolor { isRecolored = new.recolor }
        if old.dualPageBook != new.dualPageBook { layoutChanged = true }
        if old.pagePadding != new.pagePadding {
            applyPagePadding()
            layoutChanged = true
        }
        if first {
            fitMode = new.defaultFit
            updateDisplayMode()
            if pdfView.bounds.width > 1 { initialLayout() }
        } else if layoutChanged {
            layoutDidChange()
        }

        if newTheme != theme {
            let colorsChanged = theme?.highlightColor != newTheme.highlightColor
                || theme?.highlightActiveColor != newTheme.highlightActiveColor
            theme = newTheme
            pdfView.backgroundColor = newTheme.defaultBg.nsColor
            if colorsChanged { refreshSearchHighlights(force: true) }
        }
        // A no-op unless something it depends on changed.
        updateRecolor()
    }

    private func applyPagePadding() {
        let half = max(0, options.pagePadding) / 2
        pdfView.pageBreakMargins = NSEdgeInsets(top: half, left: half, bottom: half, right: half)
    }

    private func viewDidResize() {
        guard pdfView.bounds.width > 1, hasAppliedOptions else { return }
        if hasInitialLayout {
            scroller.stop()
            applyFit(keepingPosition: true)
        } else {
            initialLayout()
        }
    }

    /// First real size: fit and show the top of the first page.
    private func initialLayout() {
        hasInitialLayout = true
        applyFit(keepingPosition: false)
        pdfView.layoutDocumentView()
        if let bounds = documentView?.bounds {
            scroller.set(CGPoint(x: bounds.minX, y: bounds.minY))
        }
        tileBackdrop.refresh()
        observeScrollPosition()
        let pending = pendingNavigation
        pendingNavigation = []
        for body in pending { body() }
        scheduleStatusUpdate()
    }

    // MARK: Files

    func reloadFromDisk() {
        // A file mid-write (e.g. LaTeX) fails to parse; keep the old one.
        guard let fresh = BPDocument.openReloading(url: fileURL, renderState: renderState, password: documentPassword),
              fresh.pageCount > 0 else { return }
        let position = currentPosition
        let scale = pdfView.scaleFactor
        scroller.stop()
        search.cancel()
        if viewRotation != 0 { Self.rotate(fresh, by: viewRotation) }
        changes.resetChanges()
        pdfView.document = fresh
        updateDisplayMode()
        if fitMode == .none {
            setScaleKeepingFit(scale)
        } else {
            applyFit(keepingPosition: false)
        }
        pdfView.layoutDocumentView()
        restore(position, animated: false)
        rerunSearchQuietly()
        for feature in features { feature.documentDidReload() }
        tileBackdrop.refresh()
        scheduleStatusUpdate()
    }

    func save(to url: URL?) throws {
        try savePDF(to: url)
    }
}
