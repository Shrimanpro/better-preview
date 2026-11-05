import AppKit

/// The window's content view. Lays out the document view, the status bar and
/// the input bar with plain frames: no constraints to solve on updates.
///
/// The document fills the area below the title bar; a visible status bar
/// takes a strip at the bottom. When the status bar is hidden, a message or
/// the input bar still appears in that strip, overlaying the document.
@MainActor
final class DocumentContentView: NSView {
    let documentView: NSView
    let statusBar = StatusBar()
    var commandBar: CommandBar? {
        didSet {
            oldValue?.removeFromSuperview()
            if let commandBar { addSubview(commandBar) }
            needsLayout = true
        }
    }

    /// Left sidebar (thumbnails). Set by the sidebar feature; nil = hidden.
    var sidebarView: NSView? {
        didSet {
            guard sidebarView !== oldValue else { return }
            oldValue?.removeFromSuperview()
            if let sidebarView { addSubview(sidebarView, positioned: .below, relativeTo: statusBar) }
            needsLayout = true
        }
    }
    var sidebarWidth: CGFloat = 180 { didSet { if sidebarWidth != oldValue { needsLayout = true } } }

    var barHeight: CGFloat = 22 { didSet { if barHeight != oldValue { needsLayout = true } } }
    /// Whether the status bar reserves space (Options.statusbar / toggle-statusbar).
    var statusBarVisible = true { didSet { if statusBarVisible != oldValue { needsLayout = true } } }
    var isCommandBarShown = false { didSet { if isCommandBarShown != oldValue { needsLayout = true } } }
    /// Show the status bar strip even when hidden, for a message.
    var showsTransientStatus = false { didSet { if showsTransientStatus != oldValue { needsLayout = true } } }

    init(documentView: NSView) {
        self.documentView = documentView
        super.init(frame: .zero)
        documentView.translatesAutoresizingMaskIntoConstraints = true
        addSubview(documentView)
        addSubview(statusBar)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let top = bounds.height - safeAreaInsets.top
        let bar = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        let bottom = statusBarVisible ? barHeight : 0
        let side = sidebarView == nil ? 0 : min(sidebarWidth, bounds.width / 2)
        sidebarView?.frame = NSRect(x: 0, y: bottom, width: side, height: max(0, top - bottom))
        documentView.frame = NSRect(x: side, y: bottom, width: bounds.width - side, height: max(0, top - bottom))

        statusBar.isHidden = isCommandBarShown || !(statusBarVisible || showsTransientStatus)
        statusBar.frame = bar
        if let commandBar {
            commandBar.isHidden = !isCommandBarShown
            commandBar.frame = bar
            if let list = commandBar.completionList, !list.isHidden {
                let height = min(list.preferredHeight, max(0, top - bar.maxY))
                list.frame = NSRect(x: 0, y: bar.maxY, width: bounds.width, height: height)
            }
        }
    }
}
