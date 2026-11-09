import AppKit
import BPCore
import PDFKit

/// In-app check of page management and the sidebar, through the real window
/// and dispatch path. `BP_PAGES_SELFTEST=1 BetterPreview build/test-assets/long.pdf`
/// copies the first 8 pages of the opened PDF to build/tmp/pages-selftest.pdf,
/// opens it in a second window and runs delete / rotate / insert / reorder /
/// multi-select / export / undo / redo / save + reopen. Prints PASS/FAIL lines
/// and `PAGES SELFTEST PASS|FAIL` to stderr, writes build/tmp/pages-sidebar.png,
/// then exits (status 1 on failure). Needs build/test-assets (short.pdf, photo.png).
@MainActor
enum PagesSelfTest {
    private static var hasRun = false
    private static var ok = true
    private static var steps: [() -> Void] = []
    private static var pendingStep: (() -> Void)?
    private static var monitor: Any?
    private static var window: DocumentWindowController!
    private static var controller: PDFDocumentController!

    static func runIfRequested(window source: DocumentWindowController) {
        guard !hasRun, PDFSelfTest.featureRequested("pages", variable: "BP_PAGES_SELFTEST") else { return }
        hasRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { start(from: source) }
    }

    private static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tmp", isDirectory: true)
    private static let assets = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/test-assets", isDirectory: true)

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func check(_ condition: Bool, _ message: String) {
        log((condition ? "PASS " : "FAIL ") + message)
        if !condition { ok = false }
    }

    // MARK: Helpers

    private static var document: PDFDocument { controller.document! }

    /// The "Page N of M" number of each page; 0 for pages without one.
    private static func order(_ document: PDFDocument? = nil) -> [Int] {
        let document = document ?? self.document
        return (0..<document.pageCount).map { index in
            let text = document.page(at: index)?.string ?? ""
            guard let range = text.range(of: #"Page (\d+) of"#, options: .regularExpression) else { return 0 }
            return Int(text[range].split(separator: " ")[1]) ?? 0
        }
    }

    private static func dispatch(_ name: ActionName, _ argument: String? = nil, count: Int? = nil) {
        window.dispatch(ActionInvocation(name, argument, count: count))
    }

    private static var sidebar: SidebarView? {
        (window.features.first { $0 is SidebarFeature } as? SidebarFeature)?.sidebar
    }

    private static var pages: PagesFeature {
        controller.features.lazy.compactMap { $0 as? PagesFeature }.first!
    }

    // MARK: Run

    private static func start(from source: DocumentWindowController) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let original = PDFDocument(url: source.content.fileURL), original.pageCount >= 6 else {
            log("PAGES SELFTEST FAIL: open a PDF with at least 6 pages")
            exit(1)
        }
        let copy = PDFDocument()
        for index in 0..<min(8, original.pageCount) { copy.insert(original.page(at: index)!.copy() as! PDFPage, at: index) }
        let root = PDFOutline()
        for (title, page, parent) in [("Chapter A", 0, -1), ("Chapter B", 3, -1), ("Section B.1", 4, 1)] {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: copy.page(at: page)!, at: CGPoint(x: 0, y: 792))
            let owner = parent < 0 ? root : root.child(at: parent)!
            owner.insertChild(item, at: owner.numberOfChildren)
        }
        copy.outlineRoot = root
        let url = directory.appendingPathComponent("pages-selftest.pdf")
        try? FileManager.default.removeItem(at: url)
        guard copy.write(to: url), let controller = PDFDocumentController(url: url) else {
            log("PAGES SELFTEST FAIL: cannot write test copy")
            exit(1)
        }
        self.controller = controller
        window = DocumentWindowController(document: controller)
        window.showWindow(nil)
        defineSteps()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .applicationDefined) { event in
            guard event.subtype.rawValue == 0x5047, let step = pendingStep else { return event }
            pendingStep = nil
            step()
            return nil
        }
        next()
    }

    private static func next() {
        guard !steps.isEmpty else { return finish() }
        if ProcessInfo.processInfo.environment["BP_PAGES_SELFTEST_VERBOSE"] == "1" {
            let undo = controller.undoManager
            log("  order=\(order()) rot=\((0..<document.pageCount).map { document.page(at: $0)!.rotation }) "
                + "current=\(controller.currentPosition.page) undo=\(undo.canUndo) group=\(undo.groupingLevel)")
        }
        // Run the step inside a real event, so the undo manager groups its
        // changes per step exactly as it does per key press.
        let step = steps.removeFirst()
        pendingStep = step
        NSApp.postEvent(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 0x5047, data1: 0, data2: 0)!, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() }
    }

    private static func step(_ body: @escaping () -> Void) { steps.append(body) }

    private static func finish() {
        log(ok ? "PAGES SELFTEST PASS" : "PAGES SELFTEST FAIL")
        exit(ok ? 0 : 1)
    }

    private static func defineSteps() {
        let full = Array(1...8)
        step {
            check(order() == full, "test copy has pages 1-8: \(order())")
            dispatch(.toggleSidebar)
        }
        step {
            check(window.contentView.sidebarView != nil, "toggle-sidebar shows the sidebar")
            check(sidebar?.thumbnails.numberOfRows == 8, "sidebar has 8 rows")
            dispatch(.gotoPage, "2")
        }
        step {
            check(controller.currentPosition.page == 1, "on page 2")
            dispatch(.pageDelete)
        }
        step {
            check(order() == [1, 3, 4, 5, 6, 7, 8], "page-delete removes page 2: \(order())")
            check(sidebar?.selection == [1], "sidebar selection follows the current page")
            check(controller.isDirty, "document is dirty")
            check(sidebar?.thumbnails.numberOfRows == 7, "sidebar has 7 rows")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo restores page 2: \(order())")
            dispatch(.redo)
        }
        step {
            check(order() == [1, 3, 4, 5, 6, 7, 8], "redo deletes again")
            dispatch(.undo)
        }
        // Rotation
        step { dispatch(.gotoPage, "1") }
        step {
            dispatch(.pageRotateCW)
        }
        step {
            check(document.page(at: 0)?.rotation == 90, "page-rotate-cw rotates page 1 to 90")
            check(document.page(at: 1)?.rotation == 0, "page 2 untouched")
            dispatch(.pageRotateCCW, count: 2)
        }
        step {
            check(document.page(at: 0)?.rotation == 0 && document.page(at: 1)?.rotation == 270,
                  "2 page-rotate-ccw rotates pages 1-2")
            dispatch(.undo)
        }
        step {
            check(document.page(at: 0)?.rotation == 90 && document.page(at: 1)?.rotation == 0, "undo rotation")
            dispatch(.undo)
        }
        step {
            check(document.page(at: 0)?.rotation == 0, "undo first rotation")
            dispatch(.pageInsertBlank)
        }
        // Inserting
        step {
            check(order() == [1, 0, 2, 3, 4, 5, 6, 7, 8], "page-insert-blank after page 1: \(order())")
            check(document.page(at: 1) is RecolorPage, "blank page follows recolor")
            check(document.page(at: 1)?.bounds(for: .mediaBox).size == document.page(at: 0)?.bounds(for: .mediaBox).size,
                  "blank page has the neighbour's size")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo blank insert")
            dispatch(.pageInsert, assets.appendingPathComponent("short.pdf").path)
        }
        step {
            check(document.pageCount == 11, "page-insert short.pdf adds 3 pages: \(document.pageCount)")
            check((1...3).allSatisfy { document.page(at: $0) is RecolorPage }, "inserted pages are RecolorPages")
            check(order() == [1, 2, 1, 2, 3, 3, 4, 5, 6, 7, 8], "inserted after the current page 2: \(order())")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo PDF insert")
            dispatch(.pageInsert, assets.appendingPathComponent("photo.png").path)
        }
        step {
            check(document.pageCount == 9 && document.page(at: 1) is RecolorPage, "page-insert photo.png adds a page")
            dispatch(.undo)
        }
        // Reorder
        step {
            check(order() == full, "undo image insert")
            pages.movePages([0], to: 3)
        }
        step {
            check(order() == [2, 3, 1, 4, 5, 6, 7, 8], "move page 1 before page 4: \(order())")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo move")
            pages.movePages([3, 4], to: 0)
        }
        step {
            check(order() == [4, 5, 1, 2, 3, 6, 7, 8], "move pages 4-5 to the front: \(order())")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo multi move")
            pages.movePages([6, 7], to: 1)
        }
        step {
            check(order() == [1, 7, 8, 2, 3, 4, 5, 6], "move pages 7-8 after page 1: \(order())")
            dispatch(.undo)
        }
        // Multi-select
        step {
            check(order() == full, "undo second multi move")
            sidebar?.select([0, 2])
            dispatch(.pageRotateCW)
        }
        step {
            check(document.page(at: 0)?.rotation == 90 && document.page(at: 1)?.rotation == 0
                  && document.page(at: 2)?.rotation == 90, "rotate applies to the selection")
            check(sidebar?.selection == [0, 2], "selection kept after rotate")
            dispatch(.pageDelete)
        }
        step {
            check(order() == [2, 4, 5, 6, 7, 8], "delete applies to the selection: \(order())")
            dispatch(.undo)
        }
        step {
            check(order() == full, "undo multi delete")
            dispatch(.undo)
        }
        // Export
        step {
            check(document.page(at: 0)?.rotation == 0, "undo selection rotate")
            sidebar?.select([controller.currentPageIndex])
            let path = directory.appendingPathComponent("pages-export.pdf")
            try? FileManager.default.removeItem(at: path)
            dispatch(.pageExport, "2-3,6 \(path.path)")
        }
        step {
            let exported = PDFDocument(url: directory.appendingPathComponent("pages-export.pdf"))
            check(exported.map { order($0) } == [2, 3, 6], "page-export 2-3,6 writes those pages")
            check(PagesFeature.parseRanges("5-", pageCount: 8) == IndexSet(integersIn: 4..<8), "range 5-")
            check(PagesFeature.parseRanges("-2", pageCount: 8) == IndexSet(integersIn: 0..<2), "range -2")
            check(PagesFeature.parseRanges("foo.pdf", pageCount: 8) == nil, "a path is not a range")
            // View rotation must not reach the file, also for new pages.
            dispatch(.rotateCW)
        }
        step {
            dispatch(.gotoPage, "1")
        }
        step {
            dispatch(.pageInsertBlank)
            dispatch(.pageRotateCW)
        }
        step {
            check(document.page(at: 1)?.rotation == 180, "blank page shows view rotation + own rotation")
            dispatch(.rotateCCW)
        }
        step {
            check(document.page(at: 1)?.rotation == 90 && document.page(at: 0)?.rotation == 0,
                  "view rotation removed again")
            dispatch(.rotateCW)
        }
        // Combined edit, save, reopen.
        step {
            dispatch(.gotoPage, "3")
        }
        step {
            dispatch(.pageDelete)  // page 2 of the original
        }
        step {
            pages.movePages([0], to: 4)  // original page 1 after original 4
        }
        step {
            check(order() == [0, 3, 4, 1, 5, 6, 7, 8], "combined edit order: \(order())")
            dispatch(.save)
        }
        step {
            check(!controller.isDirty, "saved: not dirty")
            let saved = PDFDocument(url: controller.fileURL)
            check(saved.map { order($0) } == [0, 3, 4, 1, 5, 6, 7, 8], "saved order: \(saved.map { order($0) } ?? [])")
            check(saved?.page(at: 0)?.rotation == 90, "saved blank page has rotation 90 (no view rotation)")
            check(saved?.page(at: 1)?.rotation == 0, "saved page 3 unrotated")
            dispatch(.rotateCCW)
            dispatch(.undo)
        }
        step {
            check(order() == [1, 0, 3, 4, 5, 6, 7, 8], "undo after save works: \(order())")
            check(controller.isDirty, "dirty after undo")
            check(sidebar?.thumbnails.numberOfRows == 8, "sidebar follows undo")
            dispatch(.toggleRecolor)
        }
        step { }
        step { }
        step { }
        step {
            let cache = sidebar?.cache
            check((cache?.cachedCount ?? 0) > 0, "thumbnails rendered: \(cache?.cachedCount ?? 0), \((cache?.cachedBytes ?? 0) / 1024) KB")
            snapshot(window.contentView, to: directory.appendingPathComponent("pages-sidebar.png"))
            sidebar?.setMode(.outline)
            dispatch(.gotoPage, "6")
        }
        step {
            check(sidebar?.outlineTable?.numberOfRows == 3, "outline mode lists 3 entries")
            check(sidebar?.outlineTable?.selectedRow == 2, "outline marks the current section (Section B.1)")
            snapshot(window.contentView, to: directory.appendingPathComponent("pages-outline.png"))
            sidebar?.setMode(.thumbnails)
            dispatch(.toggleSidebar)
        }
        step {
            check(window.contentView.sidebarView == nil, "toggle-sidebar hides the sidebar")
            check(sidebar?.cache.cachedCount == 0, "hiding drops the thumbnails")
        }
    }

    private static func snapshot(_ view: NSView, to url: URL) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
