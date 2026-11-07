import AppKit
import BPCore
import PDFKit

/// Recolor, margin trimming, and the export guard that undoes all view-only
/// changes while saving, printing or exporting.
extension PDFDocumentController {
    // MARK: Recolor

    /// Pushes the current recolor parameters to the pages and re-renders,
    /// but only if what the pages draw actually changes.
    func updateRecolor() {
        let recolor = isRecolored ? theme.map { Recolor(theme: $0, keepHue: options.recolorKeepHue) } : nil
        tileBackdrop.setColor(recolor?.paperColor)
        guard recolor != renderState.recolor else { return }
        renderState.recolor = recolor
        redrawPages()
        scheduleStatusUpdate()
    }

    /// Re-renders the visible tiles in place, keeping layout and scroll.
    ///
    /// PDFView caches rendered tiles in layers under its page views and, on
    /// macOS 27, none of `annotationsChanged(on:)`, `layoutDocumentView()` or
    /// `needsDisplay` on the views reaches them. Toggling `displayBox` works
    /// but rebuilds every page view. Marking the layers under the page views
    /// (public CALayer API) re-renders exactly the visible tiles; pages that
    /// come into view later are rendered fresh anyway.
    func redrawPages() {
        func invalidate(_ layer: CALayer) {
            layer.setNeedsDisplay()
            layer.sublayers?.forEach(invalidate)
        }
        documentView?.subviews.forEach { $0.layer.map(invalidate) }
    }

    // MARK: Trim

    /// Starts or stops trimming to match `isTrimmed` and the padding option.
    func updateTrim() {
        trimmer.padding = max(0, options.trimPadding)
        guard isTrimmed != trimmer.isOn else { return }
        if isTrimmed, let document {
            trimmer.start(document: document, priority: visiblePageIndices())
        } else {
            trimmer.stop()
        }
        scheduleStatusUpdate()
    }

    /// The visible pages and two on either side.
    private func visiblePageIndices() -> [Int] {
        guard let document else { return [] }
        let visible = pdfView.visiblePages.map { document.index(for: $0) }
        let center = visible.isEmpty ? currentPageIndex : visible[0]
        return visible + (max(0, center - 2)...min(document.pageCount - 1, center + visible.count + 2))
    }

    /// Runs a change of page boxes (trim) keeping the reading position: same
    /// page, same spot in it, sticky fit re-applied.
    func relayoutKeepingPosition(_ change: () -> Void) {
        let position = currentPosition
        scroller.stop()
        change()
        pdfView.layoutDocumentView()
        applyFit(keepingPosition: false)
        pdfView.layoutDocumentView()
        restore(position, animated: false)
        scheduleStatusUpdate()
    }

    // MARK: Positions

    /// The box positions (marks, jump list, outline, search order) are
    /// expressed in: the page's untrimmed crop box, so they mean the same
    /// spot with trim on or off.
    func referenceBox(of page: PDFPage) -> CGRect {
        trimmer.originalBox(of: page) ?? page.bounds(for: pdfView.displayBox)
    }

    // MARK: Export guard

    /// Runs `body` with the document exactly as it is in the file: no view
    /// rotation, untrimmed crop boxes, no recolor. Use around every save,
    /// export and print, since all of them share the pages the view shows.
    func withPristinePages<T>(_ body: () throws -> T) rethrows -> T {
        let rotation = viewRotation
        if rotation != 0, let document { Self.rotate(document, by: -rotation) }
        let wasPristine = renderState.isPristine
        renderState.isPristine = true
        defer {
            renderState.isPristine = wasPristine
            if rotation != 0, let document { Self.rotate(document, by: rotation) }
            // Tiles PDFView rendered meanwhile on its threads are not recolored.
            if renderState.recolor != nil { redrawPages() }
        }
        return try trimmer.withOriginalBoxes(body)
    }
}
