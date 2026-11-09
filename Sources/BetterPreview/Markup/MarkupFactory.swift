import AppKit
import PDFKit

/// Builds standard PDF annotations (the subtypes Apple's Preview writes), so
/// markup round-trips through Preview and other readers. All geometry is in
/// page space.
@MainActor
enum MarkupFactory {
    /// One annotation per page touched by `selection`, with one quad per line.
    static func textMarkup(_ tool: MarkupTool, selection: PDFSelection,
                           style: MarkupStyle) -> [(PDFAnnotation, PDFPage)] {
        let lines = selection.selectionsByLine()
        var result: [(PDFAnnotation, PDFPage)] = []
        for page in selection.pages {
            let rects = lines.compactMap { line -> CGRect? in
                guard line.pages.contains(page) else { return nil }
                let r = line.bounds(for: page)
                return r.width > 0.5 && r.height > 0.5 ? r : nil
            }
            guard let first = rects.first else { continue }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: union, forType: tool.subtype, withProperties: nil)
            // Quad order as PDFKit (and Preview) write it: top-left, top-right,
            // bottom-left, bottom-right; relative to the bounds' origin.
            annotation.quadrilateralPoints = rects.flatMap { r -> [NSValue] in
                let x0 = r.minX - union.minX, x1 = r.maxX - union.minX
                let y0 = r.minY - union.minY, y1 = r.maxY - union.minY
                return [CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1),
                        CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y0)].map { NSValue(point: $0) }
            }
            annotation.color = style.color(for: tool)
            stamp(annotation)
            result.append((annotation, page))
        }
        return result
    }

    /// Rectangle or oval filling `rect`.
    static func shape(_ tool: MarkupTool, rect: CGRect, style: MarkupStyle) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: tool.subtype, withProperties: nil)
        annotation.color = style.strokeColor
        annotation.interiorColor = style.fillColor
        annotation.border = border(style.lineWidth)
        stamp(annotation)
        return annotation
    }

    /// Line or arrow from `start` to `end` (page space).
    static func line(arrow: Bool, from start: CGPoint, to end: CGPoint, style: MarkupStyle) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: .zero, forType: .line, withProperties: nil)
        annotation.color = style.strokeColor
        annotation.border = border(style.lineWidth)
        if arrow {
            annotation.endLineStyle = .closedArrow
            annotation.interiorColor = style.strokeColor
        }
        setLine(annotation, from: start, to: end)
        stamp(annotation)
        return annotation
    }

    /// Moves a line's endpoints (page space), growing the bounds to hold the
    /// stroke and arrow head. PDFKit keeps start/end relative to the bounds.
    static func setLine(_ annotation: PDFAnnotation, from start: CGPoint, to end: CGPoint) {
        let width = annotation.border?.lineWidth ?? 1
        let pad = max(6, width * 5)
        let bounds = CGRect(corner: start, end).insetBy(dx: -pad, dy: -pad).integral
        annotation.bounds = bounds
        annotation.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        annotation.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
    }

    /// Line endpoints in page space.
    static func lineEnds(_ annotation: PDFAnnotation) -> (CGPoint, CGPoint) {
        let o = annotation.bounds.origin
        let s = annotation.startPoint, e = annotation.endPoint
        return (CGPoint(x: s.x + o.x, y: s.y + o.y), CGPoint(x: e.x + o.x, y: e.y + o.y))
    }

    /// Freehand stroke through `points` (page space).
    static func ink(points: [CGPoint], style: MarkupStyle) -> PDFAnnotation? {
        guard let first = points.first else { return nil }
        let pad = max(4, style.lineWidth * 2)
        let box = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
            $0.union(CGRect(origin: $1, size: .zero))
        }.insetBy(dx: -pad, dy: -pad).integral
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = style.lineWidth
        path.move(to: CGPoint(x: first.x - box.minX, y: first.y - box.minY))
        for p in points.dropFirst() { path.line(to: CGPoint(x: p.x - box.minX, y: p.y - box.minY)) }
        if points.count == 1 { path.line(to: CGPoint(x: first.x - box.minX + 0.1, y: first.y - box.minY)) }
        let annotation = PDFAnnotation(bounds: box, forType: .ink, withProperties: nil)
        annotation.color = style.strokeColor
        annotation.border = border(style.lineWidth)
        annotation.add(path)
        stamp(annotation)
        return annotation
    }

    /// Sticky note whose icon sits at `point`.
    static func note(at point: CGPoint, style: MarkupStyle) -> PDFAnnotation {
        let rect = CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)
        let annotation = PDFAnnotation(bounds: rect, forType: .text, withProperties: nil)
        annotation.iconType = .note
        annotation.color = style.noteColor
        annotation.contents = ""
        stamp(annotation)
        return annotation
    }

    /// Text box: transparent, no border, like Preview's.
    static func textBox(rect: CGRect, style: MarkupStyle) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.font = style.font
        annotation.fontColor = style.textColor
        annotation.color = .clear
        annotation.border = border(0)
        annotation.alignment = .left
        annotation.contents = ""
        stamp(annotation)
        return annotation
    }

    static func border(_ width: CGFloat) -> PDFBorder {
        let border = PDFBorder()
        border.lineWidth = width
        border.style = .solid
        return border
    }

    /// Author and date, as Preview sets them.
    private static func stamp(_ annotation: PDFAnnotation) {
        annotation.userName = NSFullUserName()
        annotation.modificationDate = Date()
    }

    // MARK: Geometry edits

    /// New bounds for an annotation; ink paths are scaled into the new box.
    static func resize(_ annotation: PDFAnnotation, to rect: CGRect) {
        let old = annotation.bounds
        if MarkupKind(annotation) == .ink, old.width > 0, old.height > 0,
           rect.size != old.size, let paths = annotation.paths {
            let transform = AffineTransform(scaleByX: rect.width / old.width, byY: rect.height / old.height)
            for path in paths {
                let scaled = path.copy() as! NSBezierPath
                scaled.transform(using: transform)
                annotation.remove(path)
                annotation.add(scaled)
            }
        }
        annotation.bounds = rect
    }

    /// Distance-aware hit test: lines are hit near the segment only.
    static func hits(_ annotation: PDFAnnotation, kind: MarkupKind, point: CGPoint, tolerance: CGFloat) -> Bool {
        guard annotation.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        guard kind == .line else { return true }
        let (a, b) = lineEnds(annotation)
        return distance(point, segment: a, b) <= tolerance + (annotation.border?.lineWidth ?? 1)
    }

    static func distance(_ p: CGPoint, segment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length2 = dx * dx + dy * dy
        var t: CGFloat = 0
        if length2 > 0 { t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length2)) }
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
