import AppKit
import PDFKit

/// A mouse gesture in progress. Points are in the page's space.
enum MarkupDrag {
    case move(PDFAnnotation, PDFPage, start: CGPoint, before: AnnotationState)
    /// Corner resize; `anchor` is the fixed opposite corner.
    case resize(PDFAnnotation, PDFPage, anchor: CGPoint, before: AnnotationState)
    /// Dragging one end of a line or arrow.
    case lineEnd(PDFAnnotation, PDFPage, movingStart: Bool, before: AnnotationState)
    /// Drawing a new shape, line, arrow or text box.
    case create(MarkupTool, PDFPage, start: CGPoint, current: CGPoint)
    case ink(PDFPage, points: [CGPoint])

    var drawsPreview: Bool {
        switch self {
        case .create, .ink: true
        default: false
        }
    }
}

/// Mouse handling. Only mouse-down does any work when idle: one page lookup
/// and, if the page has annotations, a scan of them.
extension MarkupFeature {
    func viewPoint(_ event: NSEvent) -> CGPoint {
        pdfView.convert(event.locationInWindow, from: nil)
    }

    func mouseDown(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control) { return false }
        editor?.commit()
        let point = viewPoint(event)
        guard let tool else { return selectMouseDown(event, at: point) }
        if tool.isTextMarkup { return false }
        guard let page = pdfView.page(for: point, nearest: true) else { return false }
        let p = clamp(pdfView.convert(point, to: page), to: page)
        switch tool {
        case .note:
            let annotation = MarkupFactory.note(at: p, style: style)
            page.addAnnotation(annotation)
            setTool(nil)
            select(annotation)
            beginEditing(annotation, isNew: true)
        case .ink:
            drag = .ink(page, points: [p])
            refreshOverlay()
        default:
            drag = .create(tool, page, start: p, current: p)
            refreshOverlay()
        }
        return true
    }

    /// Select mode: handles of the selection, then annotations under the
    /// pointer. Misses fall through to PDFView (text selection, links).
    private func selectMouseDown(_ event: NSEvent, at point: CGPoint) -> Bool {
        if let selected, let page = selected.page, let handle = MarkupOverlay.handle(at: point, of: selected,
                                                                                    on: page, in: pdfView) {
            let before = AnnotationState(selected)
            switch handle {
            case .corner(let anchor): drag = .resize(selected, page, anchor: anchor, before: before)
            case .lineStart: drag = .lineEnd(selected, page, movingStart: true, before: before)
            case .lineEnd: drag = .lineEnd(selected, page, movingStart: false, before: before)
            }
            return true
        }
        guard let page = pdfView.page(for: point, nearest: false), !page.annotations.isEmpty else {
            if selected != nil { select(nil) }
            return false
        }
        let p = pdfView.convert(point, to: page)
        let tolerance = 4 / max(pdfView.scaleFactor, 0.01)
        let hit = page.annotations.reversed().first { annotation in
            guard annotation.shouldDisplay, let kind = MarkupKind(annotation) else { return false }
            return MarkupFactory.hits(annotation, kind: kind, point: p, tolerance: tolerance)
        }
        guard let hit, let kind = MarkupKind(hit) else {
            if selected != nil { select(nil) }
            return false
        }
        select(hit)
        if event.clickCount >= 2, kind == .note || kind == .textBox {
            beginEditing(hit, isNew: false)
        } else if kind.isMovable {
            drag = .move(hit, page, start: p, before: AnnotationState(hit))
        }
        return true
    }

    func mouseDragged(_ event: NSEvent) {
        guard let drag else { return }
        let point = viewPoint(event)
        switch drag {
        case .move(let annotation, let page, let start, let before):
            let p = pdfView.convert(point, to: page)
            var rect = before.bounds.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            // Keep at least part of it on the page.
            let box = page.bounds(for: .cropBox)
            rect.origin.x = min(max(rect.origin.x, box.minX - rect.width + 8), box.maxX - 8)
            rect.origin.y = min(max(rect.origin.y, box.minY - rect.height + 8), box.maxY - 8)
            annotation.bounds = rect
            pdfView.annotationsChanged(on: page)
        case .resize(let annotation, let page, let anchor, _):
            let p = clamp(pdfView.convert(point, to: page), to: page)
            var rect = CGRect(corner: anchor, p)
            rect.size.width = max(rect.width, 4)
            rect.size.height = max(rect.height, 4)
            if p.x < anchor.x { rect.origin.x = anchor.x - rect.width }
            if p.y < anchor.y { rect.origin.y = anchor.y - rect.height }
            MarkupFactory.resize(annotation, to: rect)
            pdfView.annotationsChanged(on: page)
        case .lineEnd(let annotation, let page, let movingStart, _):
            let p = clamp(pdfView.convert(point, to: page), to: page)
            let (s, e) = MarkupFactory.lineEnds(annotation)
            MarkupFactory.setLine(annotation, from: movingStart ? p : s, to: movingStart ? e : p)
            pdfView.annotationsChanged(on: page)
        case .create(let tool, let page, let start, _):
            var p = clamp(pdfView.convert(point, to: page), to: page)
            if event.modifierFlags.contains(.shift) { p = constrain(p, from: start, tool: tool) }
            self.drag = .create(tool, page, start: start, current: p)
        case .ink(let page, var points):
            let p = clamp(pdfView.convert(point, to: page), to: page)
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.5 / max(pdfView.scaleFactor, 0.01) {
                return
            }
            points.append(p)
            self.drag = .ink(page, points: points)
        }
        overlay?.needsDisplay = true
    }

    func mouseUp(_ event: NSEvent) {
        if case .create = drag { mouseDragged(event) }
        guard let drag else { return }
        self.drag = nil
        switch drag {
        case .move(let annotation, _, _, let before):
            recordChange(annotation, from: before, name: "Move Annotation")
        case .resize(let annotation, _, _, let before):
            recordChange(annotation, from: before, name: "Resize Annotation")
        case .lineEnd(let annotation, _, _, let before):
            recordChange(annotation, from: before, name: "Change Line")
        case .create(let tool, let page, let start, let current):
            finishCreate(tool, page: page, start: start, end: current)
        case .ink(let page, let points):
            if let annotation = MarkupFactory.ink(points: points, style: style) {
                insert([(annotation, page)], name: "Draw")
            }
        }
        refreshOverlay()
    }

    /// Creates the annotation for a finished drag. A click (tiny drag) makes
    /// a default-sized one, as Preview inserts shapes at a default size.
    func finishCreate(_ tool: MarkupTool, page: PDFPage, start: CGPoint, end: CGPoint) {
        let tiny = hypot(end.x - start.x, end.y - start.y) < 3
        let annotation: PDFAnnotation
        switch tool {
        case .line, .arrow:
            let e = tiny ? CGPoint(x: start.x + 100, y: start.y) : end
            annotation = MarkupFactory.line(arrow: tool == .arrow, from: start, to: e, style: style)
        case .text:
            let height = ceil(style.font.ascender - style.font.descender + style.font.leading) + 8
            let rect = tiny ? CGRect(x: start.x, y: start.y - height, width: 200, height: height)
                : CGRect(corner: start, end)
            annotation = MarkupFactory.textBox(rect: rect, style: style)
            page.addAnnotation(annotation)
            setTool(nil)
            select(annotation)
            beginEditing(annotation, isNew: true)
            return
        default:
            let rect = tiny ? CGRect(x: start.x - 50, y: start.y - 35, width: 100, height: 70)
                : CGRect(corner: start, end)
            annotation = MarkupFactory.shape(tool, rect: rect, style: style)
        }
        insert([(annotation, page)], name: "Add \(tool.rawValue.capitalized)")
        setTool(nil)
        select(annotation)
    }

    private func clamp(_ p: CGPoint, to page: PDFPage) -> CGPoint {
        let box = page.bounds(for: .cropBox)
        return CGPoint(x: min(max(p.x, box.minX), box.maxX), y: min(max(p.y, box.minY), box.maxY))
    }

    /// Shift: lines snap to 45 degrees, shapes become squares / circles.
    private func constrain(_ p: CGPoint, from s: CGPoint, tool: MarkupTool) -> CGPoint {
        let dx = p.x - s.x, dy = p.y - s.y
        if tool == .line || tool == .arrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: s.x + cos(angle) * length, y: s.y + sin(angle) * length)
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
    }
}
