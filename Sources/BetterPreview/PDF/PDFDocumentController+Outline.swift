import BPCore
import PDFKit

/// The table of contents, flattened for the quick-open palette.
extension PDFDocumentController {
    /// Depth-first, in document outline order. Built on first use and cached
    /// until the document is reloaded. Entries without a resolvable
    /// destination are kept (so the tree stays readable) and point at the
    /// first page.
    var outline: [OutlineEntry] {
        if let cachedOutline { return cachedOutline }
        var entries: [OutlineEntry] = []
        if let document, let root = document.outlineRoot {
            Self.flatten(root, level: 0, into: &entries) { self.position(of: $0, in: document) }
        }
        cachedOutline = entries
        return entries
    }

    private static func flatten(_ item: PDFOutline, level: Int, into entries: inout [OutlineEntry],
                                position: (PDFOutline) -> DocumentPosition) {
        for index in 0..<item.numberOfChildren {
            guard let child = item.child(at: index) else { continue }
            let title = (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            entries.append(OutlineEntry(title: title, level: level, position: position(child)))
            flatten(child, level: level + 1, into: &entries, position: position)
        }
    }

    /// The destination's top-left as page fractions of the reference box.
    /// Unspecified coordinates mean the page's top / left edge.
    private func position(of item: PDFOutline, in document: PDFDocument) -> DocumentPosition {
        guard let destination = item.destination ?? (item.action as? PDFActionGoTo)?.destination,
              let page = destination.page else { return DocumentPosition(page: 0) }
        let box = referenceBox(of: page)
        let point = destination.point
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue) / 2
        let x = point.x >= unspecified ? 0 : (point.x - box.minX) / box.width
        let y = point.y >= unspecified ? 0 : (box.maxY - point.y) / box.height
        return DocumentPosition(page: document.index(for: page),
                                x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}
