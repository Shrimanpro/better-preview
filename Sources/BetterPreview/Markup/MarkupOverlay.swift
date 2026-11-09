import AppKit
import PDFKit

/// Draws the selection outline and handles, and live previews of shapes and
/// ink being drawn, on top of the PDFView. Never takes mouse events. Only in
/// the view hierarchy while there is something to show.
@MainActor
final class MarkupOverlay: NSView {
    private weak var feature: MarkupFeature?

    init(feature: MarkupFeature) {
        self.feature = feature
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    enum Handle {
        /// Resize from a corner; the associated point is the opposite corner (page space).
        case corner(CGPoint)
        case lineStart, lineEnd
    }

    static let handleSize: CGFloat = 8

    /// Handle positions in view space, with what dragging each one does.
    static func handles(of annotation: PDFAnnotation, on page: PDFPage, in view: PDFView) -> [(CGPoint, Handle)] {
        guard let kind = MarkupKind(annotation) else { return [] }
        if kind == .line {
            let (s, e) = MarkupFactory.lineEnds(annotation)
            return [(view.convert(s, from: page), .lineStart), (view.convert(e, from: page), .lineEnd)]
        }
        guard kind.hasCornerHandles else { return [] }
        let b = annotation.bounds
        let corners = [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                       CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]
        return corners.enumerated().map { i, c in
            (view.convert(c, from: page), .corner(corners[(i + 2) % 4]))
        }
    }

    static func handle(at point: CGPoint, of annotation: PDFAnnotation, on page: PDFPage,
                       in view: PDFView) -> Handle? {
        let reach = handleSize / 2 + 3
        return handles(of: annotation, on: page, in: view)
            .first { abs($0.0.x - point.x) <= reach && abs($0.0.y - point.y) <= reach }?.1
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let feature, let pdfView = superview as? PDFView else { return }
        let accent = NSColor.controlAccentColor
        if let annotation = feature.selected, let page = annotation.page {
            let rect = pdfView.convert(annotation.bounds, from: page).insetBy(dx: -2, dy: -2)
            let outline = NSBezierPath(rect: rect.integral.insetBy(dx: 0.5, dy: 0.5))
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            if MarkupKind(annotation) != .line {
                accent.setStroke()
                outline.stroke()
            }
            for (center, _) in Self.handles(of: annotation, on: page, in: pdfView) {
                let s = Self.handleSize
                let box = NSBezierPath(ovalIn: CGRect(x: center.x - s / 2, y: center.y - s / 2, width: s, height: s))
                NSColor.white.setFill()
                box.fill()
                accent.setStroke()
                box.lineWidth = 1.5
                box.stroke()
            }
        }
        guard let drag = feature.drag else { return }
        let style = feature.style
        let scale = pdfView.scaleFactor
        switch drag {
        case .create(let tool, let page, let start, let current):
            let a = pdfView.convert(start, from: page), b = pdfView.convert(current, from: page)
            let rect = CGRect(corner: a, b)
            let path: NSBezierPath
            switch tool {
            case .oval: path = NSBezierPath(ovalIn: rect)
            case .line, .arrow:
                path = NSBezierPath()
                path.move(to: a)
                path.line(to: b)
                if tool == .arrow { Self.appendArrowHead(to: path, from: a, to: b, size: max(8, style.lineWidth * scale * 4)) }
            case .text:
                path = NSBezierPath(rect: rect)
                path.setLineDash([4, 3], count: 2, phase: 0)
            default: path = NSBezierPath(rect: rect)
            }
            path.lineWidth = tool == .text ? 1 : max(1, style.lineWidth * scale)
            if tool != .text, (tool == .rectangle || tool == .oval), let fill = style.fillColor {
                fill.setFill()
                path.fill()
            }
            (tool == .text ? accent : style.strokeColor).setStroke()
            path.stroke()
        case .ink(let page, let points):
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: pdfView.convert(first, from: page))
            for p in points.dropFirst() { path.line(to: pdfView.convert(p, from: page)) }
            path.lineWidth = max(1, style.lineWidth * scale)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            style.strokeColor.setStroke()
            path.stroke()
        default: break
        }
    }

    private static func appendArrowHead(to path: NSBezierPath, from a: CGPoint, to b: CGPoint, size: CGFloat) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        for side in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
            path.move(to: b)
            path.line(to: CGPoint(x: b.x + cos(angle + side) * size, y: b.y + sin(angle + side) * size))
        }
    }
}
