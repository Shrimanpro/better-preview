import AppKit
import PDFKit

/// A signature stamp. PDFKit writes custom-drawn annotations into the file
/// as a Stamp with an appearance stream generated from `draw`, so the image
/// shows in Apple's Preview too. Selection chrome is drawn only while the
/// document is not being exported (`PageRenderState.isPristine`).
final class SignatureAnnotation: PDFAnnotation, @unchecked Sendable {
    private var image: CGImage?
    private var renderState: PageRenderState?
    /// Written on the main thread, read by PDFKit's drawing threads; a stale
    /// read only draws one frame of old chrome.
    nonisolated(unsafe) var isSelected = false
    nonisolated(unsafe) var viewScale: CGFloat = 1
    var signatureName = ""

    convenience init(image: CGImage, bounds: CGRect, name: String, renderState: PageRenderState) {
        self.init(bounds: bounds, forType: .stamp, withProperties: nil)
        self.image = image
        self.renderState = renderState
        signatureName = name
        contents = "Signature"
        userName = "Better Preview"
        shouldDisplay = true
        shouldPrint = true
    }

    /// `PDFPage.copy()` copies annotations through this (page-export,
    /// thumbnail drag-out, decrypted export); without it the copy is an
    /// empty Stamp because the image lives in a Swift property.
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let signature = copy as? SignatureAnnotation {
            signature.image = image
            signature.renderState = renderState
            signature.signatureName = signatureName
            signature.isSelected = false
            signature.viewScale = viewScale
        }
        return copy
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        if let image {
            context.interpolationQuality = .high
            context.draw(image, in: bounds)
        }
        guard isSelected, renderState?.isPristine != true else { return }
        let scale = max(viewScale, 0.05)
        let accent = NSColor.controlAccentColor.cgColor
        context.setStrokeColor(accent)
        context.setLineWidth(1.5 / scale)
        context.stroke(bounds.insetBy(dx: 0.75 / scale, dy: 0.75 / scale))
        let handle = Self.handleSize / scale
        for rect in Self.corners(of: bounds, size: handle) {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(rect)
            context.stroke(rect)
        }
    }

    static let handleSize: CGFloat = 9

    /// Corner handles inside the bounds, in page space.
    static func corners(of b: CGRect, size: CGFloat) -> [CGRect] {
        [CGRect(x: b.minX, y: b.minY, width: size, height: size),
         CGRect(x: b.maxX - size, y: b.minY, width: size, height: size),
         CGRect(x: b.minX, y: b.maxY - size, width: size, height: size),
         CGRect(x: b.maxX - size, y: b.maxY - size, width: size, height: size)]
    }

    var aspect: CGFloat {
        guard let image, image.height > 0 else { return bounds.width / max(bounds.height, 1) }
        return CGFloat(image.width) / CGFloat(image.height)
    }
}
