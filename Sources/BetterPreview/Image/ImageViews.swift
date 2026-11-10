import AppKit
import QuartzCore

/// Scroll view that reports size changes (for sticky fit modes).
final class ImageScrollView: NSScrollView {
    var onResize: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }
}

/// Keeps a document smaller than the viewport centred.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = doc.frame.minX - (rect.width - doc.frame.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = doc.frame.minY - (rect.height - doc.frame.height) / 2 }
        return rect
    }
}

/// Layer-hosting document view: one sublayer whose contents is the CGImage.
/// The GPU scales it, so zooming and scrolling never redraw anything.
/// The view is flipped and sized in image pixels (1 pixel = 1 point at zoom 1).
/// Being layer-hosting, it takes overlays as sublayers, not subviews.
final class ImageCanvasView: NSView {
    /// Called first in keyDown; return true to consume (same as BPPDFView).
    var keyHandler: ((NSEvent) -> Bool)?
    /// Mouse drag in view points, for panning.
    var onPan: ((CGVector) -> Void)?

    /// Crop mode: takes the mouse instead of panning.
    var overlay: CropOverlay? {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    private let imageLayer = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        imageLayer.minificationFilter = .trilinear
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    func show(_ image: CGImage?, pixelSize size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frame.size != size { setFrameSize(size) }
        imageLayer.bounds = CGRect(origin: .zero, size: size)
        imageLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        imageLayer.contents = image
        CATransaction.commit()
    }

    func setPixelated(_ pixelated: Bool) {
        let filter: CALayerContentsFilter = pixelated ? .nearest : .linear
        guard imageLayer.magnificationFilter != filter else { return }
        imageLayer.magnificationFilter = filter
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        imageLayer.position = CGPoint(x: newSize.width / 2, y: newSize.height / 2)
    }

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        overlay?.mouseDown(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        if let overlay {
            overlay.mouseDragged(to: convert(event.locationInWindow, from: nil), keepAspect: event.modifierFlags.contains(.shift))
        } else {
            onPan?(CGVector(dx: event.deltaX, dy: event.deltaY))
        }
    }

    override func mouseUp(with event: NSEvent) {
        overlay?.mouseUp()
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: overlay == nil ? .openHand : .crosshair)
    }
}
