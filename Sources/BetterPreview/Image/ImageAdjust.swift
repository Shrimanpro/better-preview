import AppKit
import CoreImage

/// Colour adjustments, applied as a Core Image filter chain.
struct ImageAdjustments: Equatable {
    var exposure = 0.0      // EV, -2...2
    var contrast = 1.0      // 0.5...1.5
    var saturation = 1.0    // 0...2
    var temperature = 0.0   // -1 (cool) ... 1 (warm)
    var shadows = 0.0       // -1...1
    var highlights = 0.0    // 0...1 (recovery)
    var sharpness = 0.0     // 0...2

    var isIdentity: Bool { self == ImageAdjustments() }

    struct Slider {
        var key: String
        var title: String
        var range: ClosedRange<Double>
        var keyPath: WritableKeyPath<ImageAdjustments, Double>
    }

    static let sliders: [Slider] = [
        Slider(key: "exposure", title: "Exposure", range: -2...2, keyPath: \.exposure),
        Slider(key: "contrast", title: "Contrast", range: 0.5...1.5, keyPath: \.contrast),
        Slider(key: "saturation", title: "Saturation", range: 0...2, keyPath: \.saturation),
        Slider(key: "temperature", title: "Temperature", range: -1...1, keyPath: \.temperature),
        Slider(key: "shadows", title: "Shadows", range: -1...1, keyPath: \.shadows),
        Slider(key: "highlights", title: "Highlights", range: 0...1, keyPath: \.highlights),
        Slider(key: "sharpness", title: "Sharpness", range: 0...2, keyPath: \.sharpness),
    ]

    /// "exposure=0.5 contrast=1.2" (spaces or commas).
    static func parse(_ text: String) -> ImageAdjustments? {
        var result = ImageAdjustments()
        var any = false
        for token in text.split(whereSeparator: { $0 == " " || $0 == "," }) {
            let parts = token.split(separator: "=")
            guard parts.count == 2, let value = Double(parts[1]),
                  let slider = sliders.first(where: { $0.key == parts[0].lowercased() }) else { return nil }
            result[keyPath: slider.keyPath] = min(max(value, slider.range.lowerBound), slider.range.upperBound)
            any = true
        }
        return any ? result : nil
    }

    func apply(to input: CIImage) -> CIImage {
        var image = input
        func run(_ name: String, _ params: [String: Any]) {
            guard let filter = CIFilter(name: name) else { return }
            filter.setValue(image, forKey: kCIInputImageKey)
            for (key, value) in params { filter.setValue(value, forKey: key) }
            if let out = filter.outputImage { image = out.cropped(to: input.extent) }
        }
        if exposure != 0 { run("CIExposureAdjust", [kCIInputEVKey: exposure]) }
        if shadows != 0 || highlights != 0 {
            run("CIHighlightShadowAdjust", ["inputShadowAmount": shadows, "inputHighlightAmount": 1 - highlights])
        }
        if temperature != 0 {
            run("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500 - temperature * 2500, y: 0),
                                         "inputTargetNeutral": CIVector(x: 6500, y: 0)])
        }
        if contrast != 1 || saturation != 1 {
            run("CIColorControls", [kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation])
        }
        if sharpness != 0 { run("CISharpenLuminance", [kCIInputSharpnessKey: sharpness]) }
        return image
    }
}

enum ImageAdjustEngine {
    /// No intermediate caching: keeps memory flat on large images.
    nonisolated(unsafe) private static let context = CIContext(options: [.cacheIntermediates: false])
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Pixels per band when rendering full-size results (~1 MP: Core Image's
    /// working buffers for one band stay a few tens of MB).
    private static let bandPixels = 1 << 20

    /// For the live preview (a screen-sized proxy).
    static func render(_ image: CGImage, _ adjustments: ImageAdjustments) -> CGImage? {
        guard !adjustments.isIdentity else { return image }
        return renderBanded(CIImage(cgImage: image), adjustments)
    }

    /// Full-resolution apply. With `file`, Core Image reads the original
    /// straight from the file (oriented) instead of from a decoded bitmap;
    /// `fallback` is used when that is unavailable or does not match `size`.
    static func renderFull(file: URL?, size: CGSize, fallback: () -> CGImage?,
                           _ adjustments: ImageAdjustments) -> CGImage? {
        guard !adjustments.isIdentity else { return fallback() }
        if let file, let input = CIImage(contentsOf: file, options: [.applyOrientationProperty: true]),
           input.extent.size == size {
            return renderBanded(input.transformed(by: CGAffineTransform(translationX: -input.extent.minX,
                                                                        y: -input.extent.minY)), adjustments)
        }
        return fallback().flatMap { render($0, adjustments) }
    }

    /// Renders eagerly, in horizontal bands, into one RGBA8 sRGB bitmap.
    /// `createCGImage` instead returns an image that renders lazily, when
    /// first drawn, as one piece: for 8000×6000 that peaked at 1.6 GB and
    /// stalled the window for seconds.
    private static func renderBanded(_ input: CIImage, _ adjustments: ImageAdjustments) -> CGImage? {
        let extent = input.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        guard width > 0, height > 0,
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                     bytesPerRow: width * 4, space: sRGB,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = bitmap.data else { return nil }
        let output = adjustments.apply(to: input)
        let rowBytes = width * 4
        let band = max(16, bandPixels / width)
        var row = 0
        while row < height {
            let rows = min(band, height - row)
            // Core Image's origin is the bottom-left; bitmap row 0 is the top.
            let rect = CGRect(x: extent.minX, y: extent.minY + CGFloat(height - row - rows),
                              width: CGFloat(width), height: CGFloat(rows))
            autoreleasepool {
                context.render(output, toBitmap: data + row * rowBytes, rowBytes: rowBytes, bounds: rect,
                               format: .RGBA8, colorSpace: sRGB)
            }
            row += rows
        }
        return bitmap.makeImage()
    }
}

/// Floating panel with one slider per adjustment. Changes preview live.
@MainActor
final class ImageAdjustPanel: NSPanel, NSWindowDelegate {
    private(set) var adjustments = ImageAdjustments()
    var onChange: ((ImageAdjustments) -> Void)?
    var onApply: ((ImageAdjustments) -> Void)?
    var onCancel: (() -> Void)?
    private var finished = false
    private var sliders: [(NSSlider, ImageAdjustments.Slider)] = []

    init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 300, height: 320),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: true)
        title = "Adjust Color"
        isFloatingPanel = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        for spec in ImageAdjustments.sliders {
            let label = NSTextField(labelWithString: spec.title)
            label.font = .systemFont(ofSize: 11)
            let slider = NSSlider(value: adjustments[keyPath: spec.keyPath], minValue: spec.range.lowerBound,
                                  maxValue: spec.range.upperBound, target: self, action: #selector(changed(_:)))
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 270).isActive = true
            sliders.append((slider, spec))
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(slider)
        }
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyTapped))
        apply.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelTapped))
        let reset = NSButton(title: "Reset", target: self, action: #selector(resetTapped))
        let buttons = NSStackView(views: [reset, NSView(), cancel, apply])
        buttons.widthAnchor.constraint(equalToConstant: 270).isActive = true
        stack.addArrangedSubview(buttons)
        contentView = stack
        setContentSize(stack.fittingSize)
    }

    func set(_ values: ImageAdjustments) {
        adjustments = values
        for (slider, spec) in sliders { slider.doubleValue = values[keyPath: spec.keyPath] }
    }

    @objc private func changed(_ sender: NSSlider) {
        guard let spec = sliders.first(where: { $0.0 === sender })?.1 else { return }
        adjustments[keyPath: spec.keyPath] = sender.doubleValue
        onChange?(adjustments)
    }

    @objc private func resetTapped() {
        set(ImageAdjustments())
        onChange?(adjustments)
    }

    @objc private func applyTapped() {
        finished = true
        close()
        onApply?(adjustments)
    }

    @objc private func cancelTapped() { close() }

    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        onCancel?()
    }

    func reopen() { finished = false }
}
