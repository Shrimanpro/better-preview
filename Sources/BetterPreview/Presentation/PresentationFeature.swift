import AppKit
import BPCore
import PDFKit

/// `toggle-presentation` (F5): full screen, one page at a time, fitted to the
/// screen, no chrome, the cursor hides when idle. Exit (Esc, q, F5 or the
/// action again) restores the previous layout exactly.
///
/// It uses the system full screen (own Space, menu bar and Dock hidden by
/// macOS) and the existing `PDFDocumentController` layout state: non
/// continuous single page mode with sticky page fit, so page changes are
/// instant jumps. The window enters `.presentation` mode, which selects the
/// `[presentation]` key map. Images: not available.
@MainActor
final class PresentationFeature: WindowFeature {
    unowned let window: DocumentWindowController

    enum State { case inactive, entering, active, exiting }
    private(set) var state: State = .inactive

    /// Everything that is put back on exit.
    private struct Saved {
        var fitMode: FitMode
        var isContinuous: Bool
        var isDual: Bool
        var scale: Double
        var origin: CGPoint?
        var position: DocumentPosition
        var pageMargins: NSEdgeInsets
        var displaysPageBreaks: Bool
        var statusBarVisible: Bool
        var toolbarVisible: Bool?
        var wasFullScreen: Bool
        var frame: NSRect
        var windowBackground: NSColor?
        var viewBackground: NSColor
        var acceptsMouseMoved: Bool
    }

    private var saved: Saved?
    private var pendingExit = false
    private var enteredFullScreen = false
    private var observers: [NSObjectProtocol] = []
    private var mouseMonitor: Any?
    private var cursorTimer: Timer?
    private var fallbackTimer: Timer?

    init(window: DocumentWindowController) {
        self.window = window
        PresentationSelfTest.runIfRequested(window: window)
    }

    private var pdf: PDFDocumentController? { window.content as? PDFDocumentController }
    var isActive: Bool { state != .inactive }

    func handle(_ invocation: ActionInvocation, in window: DocumentWindowController) -> Bool {
        guard invocation.action.name == .togglePresentation else { return false }
        switch state {
        case .inactive: enter()
        case .entering: pendingExit = true
        case .active: exit()
        case .exiting: break
        }
        return true
    }

    func environmentDidChange(options: Options, theme: Theme) { refreshBackground() }
    func documentStatusDidChange() { refreshBackground() }

    // MARK: Enter

    private func enter() {
        guard let controller = pdf, let nsWindow = window.window else {
            window.showMessage("toggle-presentation: not available for images", isError: true)
            return
        }
        let contentView = window.contentView
        saved = Saved(
            fitMode: controller.fitMode, isContinuous: controller.isContinuous, isDual: controller.isDual,
            scale: controller.pdfView.scaleFactor, origin: controller.scroller.destination,
            position: controller.currentPosition, pageMargins: controller.pdfView.pageBreakMargins,
            displaysPageBreaks: controller.pdfView.displaysPageBreaks,
            statusBarVisible: contentView.statusBarVisible,
            toolbarVisible: nsWindow.toolbar?.isVisible,
            wasFullScreen: nsWindow.styleMask.contains(.fullScreen), frame: nsWindow.frame,
            windowBackground: nsWindow.backgroundColor, viewBackground: controller.pdfView.backgroundColor,
            acceptsMouseMoved: nsWindow.acceptsMouseMovedEvents)
        state = .entering
        pendingExit = false
        window.clearMessage()
        if window.mode == .command { window.closeCommandBar() }
        // Command and insert mode return here until the presentation ends.
        window.baseMode = .presentation
        window.setMode(.presentation)

        // Chrome off. The sidebar keeps its own shown state (the toggle
        // still works) and comes back on exit if it is shown then.
        contentView.statusBarVisible = false
        sidebar?.setSuppressed(true)
        nsWindow.toolbar?.isVisible = false

        // One page, fitted, no gaps.
        controller.scroller.stop()
        controller.pdfView.pageBreakMargins = NSEdgeInsetsZero
        controller.pdfView.displaysPageBreaks = false
        controller.isContinuous = false
        controller.isDual = false
        controller.fitMode = .page
        controller.layoutDidChange()
        controller.fit(.page)
        refreshBackground()

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: nsWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didEnterFullScreen() }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: nsWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didExitFullScreen() }
            },
        ]
        if saved?.wasFullScreen == true {
            didEnterFullScreen()
        } else {
            enteredFullScreen = true
            nsWindow.toggleFullScreen(nil)
            // Should the system never report back, carry on after a while.
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { if self?.state == .entering { self?.didEnterFullScreen() } }
            }
        }
        window.focusDocument()
    }

    private func didEnterFullScreen() {
        guard state == .entering else { return }
        fallbackTimer?.invalidate()
        state = .active
        if let controller = pdf {
            controller.fit(.page)
            controller.scheduleStatusUpdate()
        }
        startCursorHiding()
        window.focusDocument()
        if pendingExit {
            pendingExit = false
            // The system ignores a full screen toggle sent from inside the
            // enter notification; let the transition settle first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.exit() }
            }
        }
    }

    // MARK: Exit

    private func exit() {
        guard state == .active, let nsWindow = window.window else { return }
        state = .exiting
        stopCursorHiding()
        if enteredFullScreen, nsWindow.styleMask.contains(.fullScreen) {
            nsWindow.toggleFullScreen(nil)
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishExit() }
            }
        } else {
            finishExit()
        }
    }

    /// The system left full screen: by our `exit`, or by the user (green
    /// button, Ctrl-Cmd-F) while presenting.
    private func didExitFullScreen() {
        guard state == .entering || state == .active || state == .exiting else { return }
        if state != .exiting { stopCursorHiding() }
        finishExit()
    }

    private func finishExit() {
        guard state != .inactive, let saved else { return }
        fallbackTimer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        state = .inactive
        self.saved = nil
        enteredFullScreen = false
        pendingExit = false

        let nsWindow = window.window
        let contentView = window.contentView
        if !saved.wasFullScreen, let nsWindow, nsWindow.frame != saved.frame {
            nsWindow.setFrame(saved.frame, display: false)
        }
        contentView.statusBarVisible = saved.statusBarVisible
        sidebar?.setSuppressed(false)
        if let visible = saved.toolbarVisible { nsWindow?.toolbar?.isVisible = visible }
        nsWindow?.backgroundColor = saved.windowBackground
        nsWindow?.acceptsMouseMovedEvents = saved.acceptsMouseMoved
        contentView.layoutSubtreeIfNeeded()

        if let controller = pdf {
            controller.scroller.stop()
            controller.pdfView.pageBreakMargins = saved.pageMargins
            controller.pdfView.displaysPageBreaks = saved.displaysPageBreaks
            controller.isContinuous = saved.isContinuous
            controller.isDual = saved.isDual
            controller.fitMode = saved.fitMode
            controller.layoutDidChange()
            if saved.fitMode == .none { controller.setScaleKeepingFit(saved.scale) }
            controller.pdfView.layoutDocumentView()
            if saved.isContinuous, let origin = saved.origin {
                controller.scroller.set(origin)
            } else {
                controller.restore(saved.position, animated: false)
            }
            controller.pdfView.backgroundColor = saved.viewBackground
            controller.scheduleStatusUpdate()
        }
        if window.mode == .command { window.closeCommandBar() }
        window.baseMode = .normal
        window.setMode(.normal)
        window.focusDocument()
    }

    private var sidebar: SidebarFeature? {
        window.features.lazy.compactMap { $0 as? SidebarFeature }.first
    }

    // MARK: Teardown

    /// The window closes (possibly while presenting): drop the event
    /// monitor, timers and observers. The window goes away, so nothing of
    /// its layout needs restoring.
    func windowWillClose() {
        stopCursorHiding()
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        saved = nil
        state = .inactive
    }

    // MARK: Look

    /// Black behind the page; the theme's background when recolored, so the
    /// page and its surroundings agree.
    private func refreshBackground() {
        guard isActive, let controller = pdf else { return }
        let color = controller.isRecolored ? window.theme.defaultBg.nsColor : NSColor.black
        if controller.pdfView.backgroundColor != color { controller.pdfView.backgroundColor = color }
        if window.window?.backgroundColor != color { window.window?.backgroundColor = color }
    }

    // MARK: Cursor

    private func startCursorHiding() {
        window.window?.acceptsMouseMovedEvents = true
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.scheduleCursorHide() }
            return event
        }
        scheduleCursorHide()
    }

    private func scheduleCursorHide() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }

    private func stopCursorHiding() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
    }
}
