import AppKit
import BPCore
import PDFKit

/// Keeps a window's marks, jump list and `''` origin on their pages when
/// pages are inserted, removed or reordered (`PagesFeature.pagesDidChange`).
/// It remembers the page objects as of the last change and matches them by
/// identity (pages keep their identity across edits and undo); when the
/// document object itself was replaced (reload) pages are matched by index.
/// Pages replaced in place by new objects (OCR) arrive as pairs in the
/// notification and count as the same page.
@MainActor
final class PageMarkTracker {
    private unowned let window: DocumentWindowController
    private weak var document: PDFDocument?
    private var pages: [ObjectIdentifier] = []
    /// Keeps the remembered pages alive so their identifiers stay unique.
    private var retained: [PDFPage] = []

    init?(window: DocumentWindowController) {
        guard let controller = window.content as? PDFDocumentController else { return nil }
        self.window = window
        snapshot(controller.document)
        NotificationCenter.default.addObserver(self, selector: #selector(pagesDidChange(_:)),
                                               name: PagesFeature.pagesDidChange, object: controller)
    }

    private func snapshot(_ document: PDFDocument?) {
        self.document = document
        retained = (0..<(document?.pageCount ?? 0)).compactMap { document?.page(at: $0) }
        pages = retained.map(ObjectIdentifier.init)
    }

    @objc private func pagesDidChange(_ notification: Notification) {
        guard let controller = notification.object as? PDFDocumentController else { return }
        let current = controller.document
        let newPages = (0..<(current?.pageCount ?? 0)).compactMap { current?.page(at: $0) }.map(ObjectIdentifier.init)
        var oldPages = pages
        if let pairs = notification.userInfo?[PDFDocumentController.replacedPagesKey] as? [(old: PDFPage, new: PDFPage)] {
            for pair in pairs {
                if let i = oldPages.firstIndex(of: ObjectIdentifier(pair.old)) { oldPages[i] = ObjectIdentifier(pair.new) }
            }
        }
        let remap = current === document
            ? PageRemap(old: oldPages, new: newPages)
            : PageRemap.byIndex(oldCount: pages.count, newCount: newPages.count)
        snapshot(current)
        guard !remap.isIdentity else { return }
        window.marks.remap(remap)
        window.jumpList.remap(remap)
        window.lastJumpOrigin = window.lastJumpOrigin.flatMap(remap.map)
    }
}
