import AppKit
import os
import PDFKit

/// How pages of one document draw. Shared between the main thread (writes)
/// and PDFKit's tile-rendering threads (reads), hence the lock.
final class PageRenderState: @unchecked Sendable {
    private struct Value {
        var recolor: Recolor?
        /// Set while printing/exporting: pages draw exactly as in the file.
        var isPristine = false
    }

    private let value = OSAllocatedUnfairLock(initialState: Value())

    var recolor: Recolor? {
        get { value.withLock { $0.recolor } }
        set { value.withLock { $0.recolor = newValue } }
    }

    var isPristine: Bool {
        get { value.withLock { $0.isPristine } }
        set { value.withLock { $0.isPristine = newValue } }
    }

    /// What a page should apply right now.
    var activeRecolor: Recolor? {
        value.withLock { $0.isPristine ? nil : $0.recolor }
    }
}

/// A PDFDocument whose pages are `RecolorPage`s sharing one render state.
final class BPDocument: PDFDocument {
    private(set) var renderState = PageRenderState()

    convenience init?(url: URL, renderState: PageRenderState) {
        self.init(url: url)
        self.renderState = renderState
    }

    override var pageClass: AnyClass { RecolorPage.self }
}

/// Draws itself recolored when its document's render state asks for it.
/// PDFView renders its tiles through `draw(with:to:)` (on background threads,
/// into display-list contexts), so the view is recolored; the file itself is
/// never touched. `thumbnail(of:for:)` does NOT call this override on macOS
/// 27; use `renderedThumbnail(of:for:)` for thumbnails that follow recolor.
/// Annotations other than form fields are drawn on top un-recolored, so
/// highlight and markup colors survive.
final class RecolorPage: PDFPage {
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        defer { if LaunchTiming.isEnabled { LaunchTiming.mark("first-page-drawn") } }
        guard let recolor = (document as? BPDocument)?.renderState.activeRecolor else {
            super.draw(with: box, to: context)
            return
        }
        // PDFPage.draw applies the rotation and box origin itself: the page
        // occupies (0, 0, rotated width, rotated height).
        let size = bounds(for: box).size
        let rect = CGRect(origin: .zero, size: rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width))
        // Markup (highlights, ink, shapes, notes, stamps) keeps its colors:
        // the page content is recolored without it and the markup is drawn
        // on top. Pages without markup take the plain path at no extra cost.
        let annotations = annotations
        let overlay = annotations.filter(Self.drawsOverRecolor)
        guard !overlay.isEmpty, let pageRef else {
            recolor.draw(in: context, rect: rect) { target in
                // Pages are transparent where nothing is drawn; recolor needs paper.
                target.setFillColor(gray: 1, alpha: 1)
                target.fill(rect)
                super.draw(with: box, to: target)
            }
            return
        }
        let pageTransform = transform(for: box)
        let boxRect = bounds(for: box)
        recolor.draw(in: context, rect: rect) { target in
            target.setFillColor(gray: 1, alpha: 1)
            target.fill(rect)
            target.saveGState()
            target.concatenate(pageTransform)
            target.clip(to: boxRect)
            // The content stream alone: CoreGraphics draws no annotations.
            target.drawPDFPage(pageRef)
            // Form fields belong to the page and follow the theme.
            for annotation in annotations where Self.isRecoloredAnnotation(annotation) {
                annotation.draw(with: box, in: target)
            }
            target.restoreGState()
        }
        context.saveGState()
        context.concatenate(pageTransform)
        context.clip(to: boxRect)
        for annotation in overlay {
            if recolor.isDarkPaper, Self.isLowContrast(annotation, on: recolor) {
                // Black text boxes or navy ink would vanish on dark paper:
                // flip their lightness, keeping hue and saturation.
                LightnessInversion.draw(in: context, rect: annotation.bounds.insetBy(dx: -2, dy: -2)) {
                    annotation.draw(with: box, in: $0)
                }
            } else {
                annotation.draw(with: box, in: context)
            }
        }
        context.restoreGState()
    }

    /// Markup whose ink nearly matches dark recolor paper. Highlights are
    /// translucent washes and stay as they are; everything else is judged by its ink colour (the text
    /// colour of text boxes, the stroke colour of the rest).
    private static func isLowContrast(_ annotation: PDFAnnotation, on recolor: Recolor) -> Bool {
        let ink: NSColor?
        switch subtype(annotation) {
        case "Highlight": return false
        case "FreeText": ink = annotation.fontColor
        default: ink = annotation.color
        }
        guard let ink = ink?.usingColorSpace(.sRGB), ink.alphaComponent > 0.05 else { return false }
        return recolor.contrast(withSRGB: [ink.redComponent, ink.greenComponent, ink.blueComponent]) < 2.5
    }

    /// `PDFAnnotation.type` is the subtype without the slash ("Widget"),
    /// unlike `PDFAnnotationSubtype` raw values ("/Widget").
    private static func subtype(_ annotation: PDFAnnotation) -> String? {
        guard let type = annotation.type else { return nil }
        return type.hasPrefix("/") ? String(type.dropFirst()) : type
    }

    private static func isRecoloredAnnotation(_ annotation: PDFAnnotation) -> Bool {
        annotation.shouldDisplay && subtype(annotation) == "Widget"
    }

    /// Visible markup that is drawn un-recolored above the page. Links draw
    /// nothing and popups only show when opened, so neither counts.
    private static func drawsOverRecolor(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.shouldDisplay, let type = subtype(annotation) else { return false }
        return !["Widget", "Link", "Popup"].contains(type)
    }
}

extension PDFPage {
    /// Like `thumbnail(of:for:)` (aspect-fit into `size`, white paper), but
    /// drawn through `draw(with:to:)`, so it follows recolor and the export
    /// guard. Thread-safe. `scale` is pixels per point.
    func renderedThumbnail(of size: CGSize, for box: PDFDisplayBox, scale: CGFloat = 2) -> NSImage {
        let bounds = bounds(for: box).size
        let pageSize = rotation % 180 == 0 ? bounds : CGSize(width: bounds.height, height: bounds.width)
        let fit = min(size.width / max(pageSize.width, 1), size.height / max(pageSize.height, 1))
        let pointSize = CGSize(width: (pageSize.width * fit).rounded(), height: (pageSize.height * fit).rounded())
        guard pointSize.width >= 1, pointSize.height >= 1,
              let context = CGContext(data: nil, width: Int(pointSize.width * scale), height: Int(pointSize.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return NSImage(size: size) }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.interpolationQuality = .high
        context.scaleBy(x: fit * scale, y: fit * scale)
        draw(with: box, to: context)
        guard let image = context.makeImage() else { return NSImage(size: size) }
        return NSImage(cgImage: image, size: pointSize)
    }
}
