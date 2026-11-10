import AppKit
import BPCore
import PDFKit

/// `BP_PRESENTATION_SELFTEST=1 BetterPreview build/test-assets/long.pdf`:
/// scrolls a bit, enters presentation mode through the action path, pages with
/// the `[presentation]` keys, toggles recolor, leaves with Esc and asserts that
/// the layout (display mode, fit, zoom, scroll position, chrome, window frame)
/// is exactly as before. Prints PASS/FAIL lines and `PRESENTATION SELFTEST
/// PASS|FAIL` to stderr, then exits (1 on failure).
@MainActor
enum PresentationSelfTest {
    private static var hasRun = false
    private static var ok = true

    static func runIfRequested(window: DocumentWindowController) {
        guard !hasRun, ProcessInfo.processInfo.environment["BP_PRESENTATION_SELFTEST"] == "1" else { return }
        hasRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            Task { @MainActor in
                await run(window)
                log(ok ? "PRESENTATION SELFTEST PASS" : "PRESENTATION SELFTEST FAIL")
                exit(ok ? 0 : 1)
            }
        }
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func check(_ condition: Bool, _ message: String) {
        log((condition ? "PASS " : "FAIL ") + message)
        if !condition { ok = false }
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            await sleep(0.05)
        }
        return true
    }

    private static func keys(_ window: DocumentWindowController, _ notation: String) {
        for stroke in (try? KeyNotation.parse(notation)) ?? [] { window.handleKey(stroke) }
    }

    private struct Layout: Equatable {
        var fit: FitMode
        var continuous: Bool
        var dual: Bool
        var scale: Double
        var page: Int
        var statusBar: Bool
        var sidebar: Bool
        var fullScreen: Bool
        var mode: Mode
        var frame: NSRect
        var origin: CGPoint?
    }

    private static func layout(_ window: DocumentWindowController, _ c: PDFDocumentController) -> Layout {
        Layout(fit: c.fitMode, continuous: c.isContinuous, dual: c.isDual, scale: c.pdfView.scaleFactor,
               page: c.currentPageIndex, statusBar: window.contentView.statusBarVisible,
               sidebar: window.contentView.sidebarView != nil,
               fullScreen: window.window?.styleMask.contains(.fullScreen) ?? false, mode: window.mode,
               frame: window.window?.frame ?? .zero, origin: c.scroller.destination)
    }

    private static func run(_ window: DocumentWindowController) async {
        guard let c = window.content as? PDFDocumentController,
              let feature = window.features.compactMap({ $0 as? PresentationFeature }).first,
              let nsWindow = window.window else { return check(false, "PDF window with a presentation feature") }
        let pages = c.document?.pageCount ?? 0
        check(pages >= 12, "document has enough pages (\(pages))")

        // A non-default starting point: scrolled into the document.
        c.perform(ActionInvocation(.gotoPage, "5"))
        await sleep(1)
        c.perform(ActionInvocation(.scrollDown, nil, count: 3))
        await sleep(1)
        let before = layout(window, c)
        check(before.mode == .normal && !before.fullScreen && before.statusBar, "starts in normal mode with a status bar")

        // Enter.
        window.dispatch(ActionInvocation(.togglePresentation))
        check(window.mode == .presentation, "mode is presentation immediately")
        let entered = await waitUntil(10) { feature.state == .active }
        check(entered, "presentation becomes active (full screen entered)")
        await sleep(1)
        check(nsWindow.styleMask.contains(.fullScreen), "window is full screen")
        check(!window.contentView.statusBarVisible && window.contentView.sidebarView == nil, "status bar and sidebar hidden")
        check(!c.isContinuous && !c.isDual && c.fitMode == .page && c.pdfView.displayMode == .singlePage,
              "single page, fit page, not dual")
        if let page = c.pdfView.currentPage {
            let rect = c.pdfView.convert(page.bounds(for: c.pdfView.displayBox), from: page)
            check(rect.height <= c.pdfView.bounds.height + 1 && rect.width <= c.pdfView.bounds.width + 1,
                  "page fits the screen (\(Int(rect.width))x\(Int(rect.height)) in \(Int(c.pdfView.bounds.width))x\(Int(c.pdfView.bounds.height)))")
            check(rect.height > c.pdfView.bounds.height * 0.9 || rect.width > c.pdfView.bounds.width * 0.9, "page fills the screen")
        }
        check(c.pdfView.backgroundColor == .black, "black background")

        // Page through with the presentation key map.
        let start = c.currentPageIndex
        keys(window, "<Space>")
        check(c.currentPageIndex == start + 1, "space: next page (\(start) -> \(c.currentPageIndex))")
        keys(window, "<Right>")
        keys(window, "j")
        check(c.currentPageIndex == start + 3, "right and j: two more pages")
        keys(window, "k")
        keys(window, "<Left>")
        check(c.currentPageIndex == start + 1, "k and left: back two pages")
        keys(window, "G")
        check(c.currentPageIndex == pages - 1, "G: last page")
        keys(window, "gg")
        check(c.currentPageIndex == 0, "gg: first page")
        keys(window, "<C-r>")
        await sleep(0.3)
        check(c.isRecolored, "recolor toggles in presentation")
        keys(window, "<C-r>")
        check(!c.isRecolored && window.mode == .presentation, "recolor off again, still presenting")

        // The input bar and insert mode return to presentation mode (M2).
        window.dispatch(ActionInvocation(.searchForward))
        check(window.mode == .command, "search bar opens while presenting")
        window.commandBar(window.commandBar, submit: "zzqqxx")
        check(window.mode == .presentation && feature.state == .active, "after a search: still presentation mode")
        window.dispatch(ActionInvocation(.enterCommand))
        window.commandBarCancel(window.commandBar)
        check(window.mode == .presentation, "after a cancelled command line: still presentation mode")
        window.setMode(.insert)
        window.setMode(.normal)
        check(window.mode == .presentation, "leaving insert mode returns to presentation mode")
        let pageBefore = c.currentPageIndex
        keys(window, "j")
        check(c.currentPageIndex == pageBefore + 1, "j still pages after the input bar")
        keys(window, "k")

        // Exit with Esc.
        keys(window, "<Esc>")
        let left = await waitUntil(10) { feature.state == .inactive }
        check(left, "Esc leaves presentation")
        await sleep(1.5)
        let after = layout(window, c)
        check(after.mode == .normal, "mode back to normal")
        check(!after.fullScreen, "full screen left")
        check(after.fit == before.fit && after.continuous == before.continuous && after.dual == before.dual, "fit and display mode restored")
        check(abs(after.scale - before.scale) < 1e-4, "zoom restored (\(before.scale) -> \(after.scale))")
        check(after.statusBar == before.statusBar && after.sidebar == before.sidebar, "chrome restored")
        check(abs(after.frame.width - before.frame.width) < 2 && abs(after.frame.height - before.frame.height) < 2
              && abs(after.frame.minX - before.frame.minX) < 2 && abs(after.frame.minY - before.frame.minY) < 2,
              "window frame restored (\(before.frame) -> \(after.frame))")
        check(after.page == before.page, "page restored (\(before.page + 1) -> \(after.page + 1))")
        if let a = after.origin, let b = before.origin {
            check(abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2, "scroll position restored (\(b) -> \(a))")
        } else {
            check(false, "scroll position available")
        }
        check(c.pdfView.backgroundColor == window.theme.defaultBg.nsColor, "background restored")

        // Rapid toggle: exit requested while still entering.
        window.dispatch(ActionInvocation(.togglePresentation))
        window.dispatch(ActionInvocation(.togglePresentation))
        let settled = await waitUntil(15) { feature.state == .inactive }
        await sleep(1.5)
        let again = layout(window, c)
        check(settled && again.mode == .normal && !again.fullScreen && again.page == before.page, "enter+exit in quick succession ends normal (settled=\(settled) \(again.mode) fs=\(again.fullScreen) page \(before.page)->\(again.page))")
        check(abs(again.scale - before.scale) < 1e-4, "zoom intact after quick toggle")

        await sidebarAndTeardown(window, c, feature)
    }

    /// The sidebar is suppressed, not taken over (L1); `q` leaves the
    /// presentation (M2); closing the window while presenting tears the
    /// feature down (L6).
    private static func sidebarAndTeardown(_ window: DocumentWindowController, _ c: PDFDocumentController,
                                           _ feature: PresentationFeature) async {
        guard let sidebar = window.features.compactMap({ $0 as? SidebarFeature }).first,
              let pages = c.features.compactMap({ $0 as? PagesFeature }).first else {
            return check(false, "sidebar and pages features")
        }
        sidebar.setShown(true)
        sidebar.sidebar?.select(IndexSet([0, 1]))
        check(window.contentView.sidebarView != nil && pages.selectionProvider?().count == 2,
              "sidebar shown with two pages selected")
        window.dispatch(ActionInvocation(.togglePresentation))
        _ = await waitUntil(10) { feature.state == .active }
        check(window.contentView.sidebarView == nil && sidebar.isShown && !sidebar.isVisible,
              "presenting hides the sidebar without un-showing it")
        check(pages.selectionProvider?().isEmpty ?? true, "the hidden sidebar's selection is not used")
        window.dispatch(ActionInvocation(.toggleSidebar))
        check(window.contentView.sidebarView == nil && !sidebar.isShown, "toggle-sidebar while presenting: off, still hidden")
        window.dispatch(ActionInvocation(.toggleSidebar))
        check(window.contentView.sidebarView == nil && sidebar.isShown, "toggle-sidebar again: on, still hidden")
        keys(window, "q")
        let left = await waitUntil(10) { feature.state == .inactive }
        await sleep(1.5)
        check(left && window.window?.isVisible == true, "q leaves the presentation and keeps the window")
        check(window.contentView.sidebarView === sidebar.sidebar && sidebar.isVisible, "sidebar back after the presentation")
        sidebar.setShown(false)

        window.dispatch(ActionInvocation(.togglePresentation))
        _ = await waitUntil(10) { feature.state == .active }
        window.window?.close()
        check(feature.state == .inactive && !feature.isActive, "closing the window while presenting tears it down")
    }
}
