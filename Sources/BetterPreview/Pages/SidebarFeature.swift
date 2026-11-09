import AppKit
import BPCore

/// The thumbnail / contents sidebar. `toggle-sidebar` (`<Tab>`) and
/// `set sidebar` show it, `set sidebar-width` sizes it. Built on first
/// show; hiding it drops the thumbnail bitmaps. Image documents have no
/// sidebar.
@MainActor
final class SidebarFeature: WindowFeature {
    unowned let window: DocumentWindowController
    private(set) var sidebar: SidebarView?
    private(set) var isShown = false
    /// Hidden for now regardless of `isShown` (presentation mode); the
    /// toggle still works and takes effect when suppression ends.
    private(set) var isSuppressed = false
    /// Whether the sidebar is on screen.
    var isVisible: Bool { isShown && !isSuppressed }
    private var appliedOption: Bool?
    private var appliedWidth: Double?

    init(window: DocumentWindowController) {
        self.window = window
        PagesSelfTest.runIfRequested(window: window)
    }

    private var controller: PDFDocumentController? { window.content as? PDFDocumentController }

    func handle(_ invocation: ActionInvocation, in window: DocumentWindowController) -> Bool {
        guard invocation.action.name == .toggleSidebar else { return false }
        if controller == nil {
            window.showMessage("toggle-sidebar: not available for images", isError: false)
        } else {
            setShown(!isShown)
        }
        return true
    }

    func environmentDidChange(options: Options, theme: Theme) {
        if appliedWidth != options.sidebarWidth {
            appliedWidth = options.sidebarWidth
            window.contentView.sidebarWidth = CGFloat(min(max(options.sidebarWidth, Double(SidebarMetrics.minWidth)),
                                                          Double(SidebarMetrics.maxWidth)))
        }
        // Like the status bar: the option applies when it changes, the
        // toggle overrides it until then.
        if appliedOption != options.sidebar {
            appliedOption = options.sidebar
            if controller != nil { setShown(options.sidebar) }
        }
        sidebar?.apply(theme: theme)
    }

    func documentStatusDidChange() {
        guard isVisible else { return }
        sidebar?.documentStatusDidChange()
    }

    func setShown(_ shown: Bool) {
        guard shown != isShown, controller != nil else { return }
        let wasVisible = isVisible
        isShown = shown
        updateVisibility(wasVisible: wasVisible)
    }

    /// Presentation mode hides the sidebar without changing `isShown`.
    func setSuppressed(_ suppressed: Bool) {
        guard suppressed != isSuppressed else { return }
        let wasVisible = isVisible
        isSuppressed = suppressed
        updateVisibility(wasVisible: wasVisible)
    }

    private func updateVisibility(wasVisible: Bool) {
        guard isVisible != wasVisible, let controller else { return }
        if isVisible {
            let sidebar = sidebar ?? makeSidebar(controller)
            window.contentView.sidebarView = sidebar
            window.contentView.layoutSubtreeIfNeeded()
            sidebar.willShow()
        } else {
            window.contentView.sidebarView = nil
            sidebar?.didHide()
            if window.window?.firstResponder === sidebar?.thumbnails { window.focusDocument() }
        }
    }

    private func makeSidebar(_ controller: PDFDocumentController) -> SidebarView {
        let view = SidebarView(controller: controller, window: window)
        let pages = controller.features.lazy.compactMap { $0 as? PagesFeature }.first
        view.pages = pages
        pages?.selectionProvider = { [weak self, weak view] in
            // Only a selection the user can see is acted on.
            guard let self, isVisible, let view, window.contentView.sidebarView === view else { return IndexSet() }
            return view.selection
        }
        view.apply(theme: window.theme)
        sidebar = view
        return view
    }
}
