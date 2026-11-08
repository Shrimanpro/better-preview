import AppKit
import PDFKit

/// The BP_SCRIPT `snapshot` step. `cacheDisplay` captures the view tree but
/// not PDFKit's tiled page layers, so PDF pages come out blank; this draws
/// each visible page through `PDFPage.draw(with:to:)` (the same path the tiles
/// use, so recolor, trimmed crop boxes and annotations show as displayed)
/// into the PDF view's area, then redraws the app's own overlays (markup
/// overlay, text editor, command bar) on top. PDFView's own selection and
/// search highlights and page shadows are not reproduced. No screen-recording
/// permission is needed: everything is rendered in-process.
@MainActor
enum DebugSnapshot {
    static func png(of view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let pdfViews = descendants(of: view).compactMap { $0 as? PDFView }.filter { !$0.isHiddenOrHasHiddenAncestor }
        if !pdfViews.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            let cg = context.cgContext
            // Work in pixels with the origin at the bottom left, whatever the
            // context's default transform is.
            cg.concatenate(cg.ctm.inverted())
            let scale = CGFloat(rep.pixelsWide) / max(view.bounds.width, 1)
            cg.scaleBy(x: scale, y: scale)
            for pdfView in pdfViews { composite(pdfView, in: view, cg) }
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep.representation(using: .png, properties: [:])
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    /// `rect` in `from`'s coordinates -> the root view, bottom-left origin.
    private static func rootRect(_ rect: CGRect, from: NSView, root: NSView) -> CGRect {
        var r = root.convert(rect, from: from)
        if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        return r
    }

    private static func composite(_ pdfView: PDFView, in root: NSView, _ cg: CGContext) {
        // The page area: the document view's visible part (no scrollers).
        var area = pdfView.bounds
        if let documentView = pdfView.documentView {
            area = area.intersection(pdfView.convert(documentView.visibleRect, from: documentView))
        }
        cg.saveGState()
        cg.clip(to: rootRect(area, from: pdfView, root: root))
        let box = pdfView.displayBox
        for page in pdfView.visiblePages {
            let target = rootRect(pdfView.convert(page.bounds(for: box), from: page), from: pdfView, root: root)
            let size = page.bounds(for: box).size
            let rotated = page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
            guard target.width > 0, rotated.width > 0, rotated.height > 0 else { continue }
            cg.saveGState()
            cg.setFillColor(gray: 1, alpha: 1)
            cg.fill(target)
            cg.translateBy(x: target.minX, y: target.minY)
            cg.scaleBy(x: target.width / rotated.width, y: target.height / rotated.height)
            cg.interpolationQuality = .high
            page.draw(with: box, to: cg)
            cg.restoreGState()
        }
        cg.restoreGState()
        for overlay in overlays(above: pdfView, root: root) {
            draw(overlay, root: root, cg)
        }
    }

    /// The app's views drawn over the pages: the PDF view's own non-PDFKit
    /// subviews, and later siblings (of it or its ancestors) that overlap it.
    private static func overlays(above pdfView: PDFView, root: NSView) -> [NSView] {
        let pdfKit = Bundle(for: PDFView.self)
        var result = pdfView.subviews.filter { !$0.isHidden && Bundle(for: type(of: $0)) != pdfKit }
        let frame = root.convert(pdfView.bounds, from: pdfView)
        var branch: NSView = pdfView
        while let parent = branch.superview, branch !== root {
            if let index = parent.subviews.firstIndex(where: { $0 === branch }) {
                result += parent.subviews[(index + 1)...].filter {
                    !$0.isHidden && root.convert($0.bounds, from: $0).intersects(frame)
                }
            }
            branch = parent
        }
        return result
    }

    private static func draw(_ view: NSView, root: NSView, _ cg: CGContext) {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage else { return }
        cg.draw(image, in: rootRect(view.bounds, from: view, root: root))
    }
}
