import AppKit
import BPCore
import PDFKit
import UniformTypeIdentifiers

/// Page management: delete, rotate (saved to the file), insert from a file,
/// insert blank, export a range, reorder. Every change is undoable through
/// the controller's undo manager and marks the document dirty.
///
/// All structural edits go through two exact inverses, `removePages(at:)` and
/// `insertPages(_:at:)` (indices ascending, as final positions), plus
/// `rotatePages` and `movePages`. Pages keep their identity across undo, so
/// the sidebar's thumbnail cache (keyed by page object) stays valid.
///
/// View-only state is kept out of the file: pages leaving the document lose
/// the view rotation and trim crop, pages entering it gain the view rotation.
@MainActor
final class PagesFeature: PDFFeature {
    /// Posted (object: the PDFDocumentController) after pages were inserted,
    /// removed, moved or rotated, and after a reload.
    static let pagesDidChange = Notification.Name("BPPagesDidChange")

    unowned let controller: PDFDocumentController
    /// Set by the sidebar while it is shown: the selected page indices.
    var selectionProvider: (() -> IndexSet)?

    init(controller: PDFDocumentController) {
        self.controller = controller
    }

    func handle(_ invocation: ActionInvocation) -> Bool {
        let argument = invocation.action.argument?.trimmingCharacters(in: .whitespaces)
        switch invocation.action.name {
        case .pageDelete: deletePages(targets(count: invocation.count))
        case .pageRotateCW: rotatePages(targets(count: invocation.count), by: 90)
        case .pageRotateCCW: rotatePages(targets(count: invocation.count), by: -90)
        case .pageInsert:
            if let argument, !argument.isEmpty {
                insertFiles([resolve(argument)], at: insertionIndex)
            } else {
                showInsertPanel()
            }
        case .pageInsertBlank: insertBlankPage(at: insertionIndex)
        case .pageExport: export(argument)
        default: return false
        }
        return true
    }

    func documentDidReload() {
        NotificationCenter.default.post(name: Self.pagesDidChange, object: controller)
    }

    // MARK: Targets

    private var document: PDFDocument? { controller.document }
    private var pageCount: Int { document?.pageCount ?? 0 }

    /// The sidebar's multi-selection if there is one, else `count` pages
    /// from the current one. (A single selected thumbnail is the current
    /// page anyway; the reading position is more up to date while a jump is
    /// still animating.)
    func targets(count: Int?) -> IndexSet {
        if count == nil, let selection = selectionProvider?(), selection.count > 1 {
            return selection.filteredIndexSet { $0 < pageCount }
        }
        let first = currentPage
        return IndexSet(integersIn: first..<min(pageCount, first + max(1, count ?? 1)))
    }

    /// The page the viewport is on or animating to.
    private var currentPage: Int {
        min(max(controller.currentPosition.page, 0), max(pageCount - 1, 0))
    }

    /// After the last selected page, else after the current page.
    private var insertionIndex: Int {
        if let selection = selectionProvider?(), selection.count > 1, let last = selection.last, last < pageCount {
            return last + 1
        }
        return min(currentPage + 1, pageCount)
    }

    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return controller.fileURL.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }

    private func message(_ text: String, error: Bool = false) {
        controller.host?.showMessage(text, isError: error)
    }

    // MARK: Operations

    func deletePages(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        guard indices.count < pageCount else {
            return message("page-delete: a document needs at least one page", error: true)
        }
        removePages(at: indices, focus: indices.first!)
        controller.undoManager.setActionName(indices.count == 1 ? "Delete Page" : "Delete Pages")
    }

    func rotatePages(_ indices: IndexSet, by degrees: Int) {
        guard let document, !indices.isEmpty else { return }
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            page.rotation = Self.normalized(page.rotation + degrees)
        }
        controller.undoManager.registerUndo(withTarget: self) { $0.rotatePages(indices, by: -degrees) }
        controller.undoManager.setActionName(degrees > 0 ? "Rotate Right" : "Rotate Left")
        didChangePages(focus: nil)
    }

    /// Moves pages so they end up, in order, just before the page that is
    /// now at `destination` (a gap index, 0...pageCount).
    func movePages(_ indices: IndexSet, to destination: Int) {
        guard let document, !indices.isEmpty else { return }
        let before = indices.count(in: 0..<destination)
        let start = destination - before
        let final = IndexSet(integersIn: start..<start + indices.count)
        guard final != indices else { return }
        let pages = indices.compactMap { document.page(at: $0) }
        move(pages, from: indices, to: final)
        controller.undoManager.setActionName(indices.count == 1 ? "Move Page" : "Move Pages")
    }

    private func move(_ pages: [PDFPage], from old: IndexSet, to new: IndexSet) {
        guard let document else { return }
        for index in old.reversed() { document.removePage(at: index) }
        for (page, index) in zip(pages, new) { document.insert(page, at: index) }
        controller.undoManager.registerUndo(withTarget: self) { $0.move(pages, from: new, to: old) }
        didChangePages(focus: new.first)
    }

    func insertBlankPage(at index: Int) {
        guard let document else { return }
        let reference = document.page(at: max(0, min(index - 1, pageCount - 1)))
        let size = reference.map { controller.referenceBox(of: $0).size } ?? CGSize(width: 612, height: 792)
        let page = RecolorPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        // Same orientation as its neighbour, without the view rotation.
        page.rotation = Self.normalized((reference?.rotation ?? 0) - controller.viewRotation)
        insertPages([page], at: IndexSet(integer: index))
        controller.undoManager.setActionName("Insert Blank Page")
    }

    /// Inserts every page of each PDF, or each image as one page, at `index`.
    @discardableResult
    func insertFiles(_ urls: [URL], at index: Int) -> Bool {
        var pages: [PDFPage] = []
        for url in urls {
            guard let loaded = Self.loadPages(from: url, renderState: controller.renderState) else {
                message("page-insert: cannot read \(url.lastPathComponent)", error: true)
                return false
            }
            pages += loaded
        }
        guard !pages.isEmpty else { return false }
        insertPages(pages, at: IndexSet(integersIn: index..<index + pages.count))
        controller.undoManager.setActionName(pages.count == 1 ? "Insert Page" : "Insert Pages")
        message("Inserted \(pages.count) page\(pages.count == 1 ? "" : "s")")
        return true
    }

    /// Pages ready to insert: `RecolorPage`s (so they follow recolor),
    /// detached from any document.
    static func loadPages(from url: URL, renderState: PageRenderState) -> [PDFPage]? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) ?? false {
            guard let source = BPDocument(url: url, renderState: renderState), !source.isLocked else { return nil }
            var pages: [PDFPage] = []
            while source.pageCount > 0, let page = source.page(at: 0) {
                source.removePage(at: 0)
                pages.append(page)
            }
            return pages
        }
        guard let image = NSImage(contentsOf: url), image.isValid,
              let page = RecolorPage(image: image) else { return nil }
        return [page]
    }

    // MARK: Primitives (exact inverses)

    /// Removes the pages at `indices`; undo puts the same page objects back.
    private func removePages(at indices: IndexSet, focus: Int) {
        guard let document else { return }
        var pages: [PDFPage] = []
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            // Leave the document as the file has it: untrimmed, unrotated view.
            if let original = controller.trimmer.originalBox(of: page) { page.setBounds(original, for: .cropBox) }
            pages.append(page)
        }
        for index in indices.reversed() { document.removePage(at: index) }
        for page in pages { page.rotation = Self.normalized(page.rotation - controller.viewRotation) }
        controller.undoManager.registerUndo(withTarget: self) { $0.insertPages(pages, at: indices) }
        didChangePages(focus: min(focus, document.pageCount - 1))
    }

    /// Inserts `pages` so they end up at `indices` (ascending).
    private func insertPages(_ pages: [PDFPage], at indices: IndexSet) {
        guard let document else { return }
        for (page, index) in zip(pages, indices) {
            page.rotation = Self.normalized(page.rotation + controller.viewRotation)
            document.insert(page, at: min(index, document.pageCount))
        }
        controller.undoManager.registerUndo(withTarget: self) { $0.removePages(at: indices, focus: indices.first!) }
        didChangePages(focus: indices.first)
    }

    /// Keeps the view, search, outline and trim consistent with the new pages
    /// and shows `focus` (else keeps the reading position).
    private func didChangePages(focus: Int?) {
        let position = controller.currentPosition
        controller.cachedOutline = nil
        if controller.isTrimmed {
            controller.trimmer.stop()
            controller.updateTrim()
        }
        controller.scroller.stop()
        controller.pdfView.layoutDocumentView()
        controller.applyFit(keepingPosition: false)
        controller.pdfView.layoutDocumentView()
        if let focus {
            let page = min(max(focus, 0), pageCount - 1)
            controller.restore(DocumentPosition(page: page, x: position.x, y: page == position.page ? position.y : 0),
                               animated: false)
        } else {
            controller.restore(position, animated: false)
        }
        controller.rerunSearchQuietly()
        controller.isDirty = true
        controller.scheduleStatusUpdate()
        NotificationCenter.default.post(name: Self.pagesDidChange, object: controller)
    }

    static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    // MARK: Panels

    private func showInsertPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = controller.fileURL.deletingLastPathComponent()
        panel.prompt = "Insert"
        let index = insertionIndex
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            insertFiles(panel.urls, at: index)
        }
        if let window = controller.pdfView.window { panel.beginSheetModal(for: window, completionHandler: done) }
        else { done(panel.runModal()) }
    }

    // MARK: Export

    /// `page-export [<ranges>] [path] [force]`: ranges like `3-7`, `2,5,9-`,
    /// `-4`. No ranges: the sidebar selection or the current page. No path:
    /// the Save panel. The path may be quoted or contain spaces; an existing
    /// file is replaced only with `force`, and never the open document.
    private func export(_ argument: String?) {
        var words = CommandParser.splitArgumentWords(argument ?? "")
        var indices = IndexSet()
        if let first = words.first, !first.quoted, let parsed = Self.parseRanges(first.text, pageCount: pageCount) {
            indices = parsed
            words.removeFirst()
        } else {
            indices = targets(count: nil)
        }
        guard !indices.isEmpty else { return message("page-export: no pages in range", error: true) }
        var force = false
        if let last = words.last, !last.quoted, ["force", "!"].contains(last.text.lowercased()) {
            force = true
            words.removeLast()
        }
        if !words.isEmpty {
            // Several bare words: one path with spaces ("my notes.pdf").
            guard words.count == 1 || !words.contains(where: \.quoted) else {
                return message("page-export: unexpected '\(words[1].text)' (page-export [ranges] [path] [force])",
                               error: true)
            }
            let url = resolve(words.map(\.text).joined(separator: " "))
            if FileManager.default.fileExists(atPath: url.path), !force,
               url != controller.fileURL.standardizedFileURL {
                return message("page-export: \(url.lastPathComponent) exists (add \"force\" to replace it)", error: true)
            }
            writePages(indices, to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = controller.fileURL.deletingLastPathComponent()
        let base = controller.fileURL.deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(base) (\(Self.describe(indices))).pdf"
        // The panel itself asks before replacing an existing file.
        let done: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.writePages(indices, to: url)
        }
        if let window = controller.pdfView.window { panel.beginSheetModal(for: window, completionHandler: done) }
        else { done(panel.runModal()) }
    }

    /// Why the pages may not be copied out of the document, or nil. A
    /// document unlocked with only the user password keeps its owner
    /// restrictions; a plain copy of its pages would drop them.
    var copyRestriction: String? {
        guard let document, document.isEncrypted, document.permissionsStatus != .owner,
              PDFExporter.hasRestrictions(document) else { return nil }
        return "the document's owner restricts it; open it with the owner password to export pages"
    }

    /// Pages as in the file (no view rotation, trim or recolor), as PDF data.
    /// Nil when there is nothing to copy or `copyRestriction` forbids it.
    func pdfData(for indices: IndexSet) -> Data? {
        guard let document, copyRestriction == nil else { return nil }
        return controller.withPristinePages {
            let output = PDFDocument()
            for index in indices {
                guard let copy = document.page(at: index)?.copy() as? PDFPage else { continue }
                output.insert(copy, at: output.pageCount)
            }
            return output.pageCount > 0 ? output.dataRepresentation() : nil
        }
    }

    @discardableResult
    func writePages(_ indices: IndexSet, to url: URL) -> Bool {
        if url.standardizedFileURL == controller.fileURL.standardizedFileURL {
            message("page-export: that is the open file; use page-delete and save", error: true)
            return false
        }
        if let copyRestriction {
            message("page-export: \(copyRestriction)", error: true)
            return false
        }
        guard let data = pdfData(for: indices) else {
            message("page-export: could not copy the pages", error: true)
            return false
        }
        do {
            try AtomicWrite.write(to: url) { temp in try data.write(to: temp) }
            message("Exported \(Self.describe(indices)) to \(url.lastPathComponent)")
            return true
        } catch {
            message("page-export: \(error.localizedDescription)", error: true)
            return false
        }
    }

    /// 1-based ranges to 0-based indices; nil if `text` is not a range list.
    static func parseRanges(_ text: String, pageCount: Int) -> IndexSet? {
        var result = IndexSet()
        for part in text.split(separator: ",") {
            let bounds = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(bounds.count), bounds.allSatisfy({ $0.isEmpty || Int($0) != nil }),
                  !bounds.allSatisfy(\.isEmpty) else { return nil }
            let low = Int(bounds[0]) ?? 1
            let high = bounds.count == 1 ? low : (Int(bounds[1]) ?? pageCount)
            let from = max(1, min(low, high)), to = min(pageCount, max(low, high))
            if from <= to { result.insert(integersIn: (from - 1)..<to) }
        }
        return result
    }

    /// "page 3", "pages 3-7", "pages 1-2, 5".
    static func describe(_ indices: IndexSet) -> String {
        let parts = indices.rangeView.map { $0.count == 1 ? "\($0.lowerBound + 1)" : "\($0.lowerBound + 1)-\($0.upperBound)" }
        return (indices.count == 1 ? "page " : "pages ") + parts.joined(separator: ", ")
    }
}
