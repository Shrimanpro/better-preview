import AppKit
import BPCore
import PDFKit

/// Recolor, and the export guard that undoes all view-only
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

    // MARK: Positions

    /// The box positions (marks, jump list, search order) are expressed in.
    func referenceBox(of page: PDFPage) -> CGRect {
        page.bounds(for: pdfView.displayBox)
    }

    // MARK: Export guard

    /// Runs `body` with the document exactly as it is in the file: no view
    /// rotation, no recolor. Use around every save,
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
        return try body()
    }
}
