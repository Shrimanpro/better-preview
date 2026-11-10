import AppKit
import QuartzCore

/// Draggable crop selection drawn as layers on the (layer-hosting) canvas.
/// `rect` is in image pixels with a top-left origin, like the canvas.
@MainActor
final class CropOverlay {
    private(set) var rect: CGRect
    private let imageSize: CGSize
    private var zoom: CGFloat
    private let root = CALayer()
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()

    private enum Drag {
        case move(grab: CGPoint)
        case resize(left: Bool, right: Bool, top: Bool, bottom: Bool, start: CGRect)
        case create(anchor: CGPoint)
    }
    private var drag: Drag?

    init(canvasLayer: CALayer, imageSize: CGSize, zoom: CGFloat, initial: CGRect? = nil) {
        self.imageSize = imageSize
        self.zoom = max(zoom, 0.001)
        rect = initial ?? CGRect(x: imageSize.width * 0.1, y: imageSize.height * 0.1,
                                 width: imageSize.width * 0.8, height: imageSize.height * 0.8)
        root.frame = CGRect(origin: .zero, size: imageSize)
        root.isGeometryFlipped = canvasLayer.isGeometryFlipped
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.55).cgColor
        border.fillColor = nil
        border.strokeColor = NSColor.white.cgColor
        handles.fillColor = NSColor.white.cgColor
        handles.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        for layer in [dim, border, handles] { root.addSublayer(layer) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        canvasLayer.addSublayer(root)
        CATransaction.commit()
        redraw()
    }

    func remove() { root.removeFromSuperlayer() }

    func zoomChanged() { redraw() }

    func setZoom(_ value: CGFloat) {
        zoom = max(value, 0.001)
        redraw()
    }

    func set(rect new: CGRect) {
        rect = clamp(new)
        redraw()
    }

    private func clamp(_ r: CGRect) -> CGRect {
        let bounds = CGRect(origin: .zero, size: imageSize)
        return r.standardized.intersection(bounds).integral.intersection(bounds)
    }

    // MARK: Drawing

    private var handlePoints: [(CGPoint, (l: Bool, r: Bool, t: Bool, b: Bool))] {
        let r = rect
        return [
            (CGPoint(x: r.minX, y: r.minY), (true, false, true, false)),
            (CGPoint(x: r.midX, y: r.minY), (false, false, true, false)),
            (CGPoint(x: r.maxX, y: r.minY), (false, true, true, false)),
            (CGPoint(x: r.maxX, y: r.midY), (false, true, false, false)),
            (CGPoint(x: r.maxX, y: r.maxY), (false, true, false, true)),
            (CGPoint(x: r.midX, y: r.maxY), (false, false, false, true)),
            (CGPoint(x: r.minX, y: r.maxY), (true, false, false, true)),
            (CGPoint(x: r.minX, y: r.midY), (true, false, false, false)),
        ]
    }

    private func redraw() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let full = CGRect(origin: .zero, size: imageSize)
        let dimPath = CGMutablePath()
        dimPath.addRect(full)
        dimPath.addRect(rect)
        dim.path = dimPath
        border.path = CGPath(rect: rect, transform: nil)
        border.lineWidth = 1.5 / zoom
        let size = 9 / zoom
        let handlePath = CGMutablePath()
        for (point, _) in handlePoints {
            handlePath.addRect(CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        }
        handles.path = handlePath
        handles.lineWidth = 1 / zoom
        CATransaction.commit()
    }

    // MARK: Mouse (canvas coordinates, top-left origin)

    func mouseDown(at point: CGPoint) {
        let reach = 10 / zoom
        for (p, h) in handlePoints where abs(p.x - point.x) <= reach && abs(p.y - point.y) <= reach {
            drag = .resize(left: h.l, right: h.r, top: h.t, bottom: h.b, start: rect)
            return
        }
        if rect.contains(point) {
            drag = .move(grab: CGPoint(x: point.x - rect.minX, y: point.y - rect.minY))
        } else {
            drag = .create(anchor: point)
            rect = clamp(CGRect(origin: point, size: .zero))
        }
    }

    func mouseDragged(to point: CGPoint, keepAspect: Bool) {
        guard let drag else { return }
        switch drag {
        case .move(let grab):
            var origin = CGPoint(x: point.x - grab.x, y: point.y - grab.y)
            origin.x = min(max(origin.x, 0), imageSize.width - rect.width)
            origin.y = min(max(origin.y, 0), imageSize.height - rect.height)
            rect.origin = CGPoint(x: origin.x.rounded(), y: origin.y.rounded())
        case .create(let anchor):
            rect = clamp(CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
                                width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)))
        case .resize(let left, let right, let top, let bottom, let start):
            var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
            if left { minX = point.x }
            if right { maxX = point.x }
            if top { minY = point.y }
            if bottom { maxY = point.y }
            var r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            if keepAspect, start.height > 0, (left || right), (top || bottom) {
                let aspect = start.width / start.height
                r.size.height = r.width / aspect
                if top { r.origin.y = start.maxY - r.height }
            }
            rect = clamp(r)
        }
        redraw()
    }

    func mouseUp() { drag = nil }
}
