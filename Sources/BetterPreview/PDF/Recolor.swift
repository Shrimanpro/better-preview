import BPCore
import CoreGraphics

/// zathura-style page recoloring, done with CoreGraphics blend-mode fills over
/// the freshly drawn page, so it costs a few full-tile fills per tile.
///
/// Plain mode (zathura `recolor`), with L = `recolorLightColor` (paper) and
/// D = `recolorDarkColor` (ink), per channel c:
///
/// 1. `.saturation` with any gray: v = Lum(x) = 0.3r + 0.59g + 0.11b (the
///    same weights zathura uses), so the output is a pure function of v.
/// 2. `.difference` with s_c = 1 where L_c < D_c, else 0: w = |v - s_c|,
///    i.e. w = v where paper is lighter than ink, 1 - v where it is darker.
/// 3. `.multiply` with m_c = (B_c - A_c) / (1 - A_c): w * m_c.
/// 4. `.screen` with A_c: A_c + w m_c (1 - A_c) = A_c + (B_c - A_c) w,
///
/// where A = min(L, D), B = max(L, D). Both cases reduce to exactly
/// out_c = D_c + (L_c - D_c) * v, a linear ramp from ink to paper.
///
/// Keep-hue mode (zathura `recolor-keephue`): the ramp above is run with the
/// neutral grays Lum(L) and Lum(D) as endpoints, then the original page is
/// composited with `.color`, giving SetLum(original, Lum(L)·v + Lum(D)·(1-v)):
/// hue and saturation of colored content survive and only lightness is
/// remapped. Unlike zathura (which leaves grays neutral) a final per-channel
/// affine tint out_c = α_c + β_c·k maps neutral gray k exactly back onto the
/// theme ramp, so paper and ink still get the theme colors; colored content
/// receives the same mild tint. The tint uses `.difference` (for β_c < 0),
/// `.plusDarker`, `.colorDodge` (β_c > 1), `.multiply` (β_c < 1) and
/// `.plusLighter`, skipping no-op steps.
///
/// Immutable and thread-safe: PDFKit draws tiles on background threads.
struct Recolor: Equatable, Sendable {
    /// sRGB components.
    let light: [CGFloat]
    let dark: [CGFloat]
    let keepHue: Bool

    init(theme: Theme, keepHue: Bool) {
        light = [theme.recolorLightColor.r, theme.recolorLightColor.g, theme.recolorLightColor.b]
        dark = [theme.recolorDarkColor.r, theme.recolorDarkColor.g, theme.recolorDarkColor.b]
        self.keepHue = keepHue
    }

    /// What white paper becomes (in both modes): the theme's light colour.
    var paperColor: CGColor {
        CGColor(colorSpace: Self.sRGB, components: light + [1]) ?? CGColor(gray: 1, alpha: 1)
    }

    /// True when the paper is dark (a dark theme), where dark markup needs
    /// help to stay visible.
    var isDarkPaper: Bool { Self.relativeLuminance(light) < 0.2 }

    /// WCAG contrast ratio (1...21) of an sRGB colour against the paper.
    func contrast(withSRGB rgb: [CGFloat]) -> CGFloat {
        let a = Self.relativeLuminance(rgb), b = Self.relativeLuminance(light)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ rgb: [CGFloat]) -> CGFloat {
        func linear(_ c: CGFloat) -> CGFloat { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
    }

    /// Draws `content` (an opaque, normally colored page filling `rect`)
    /// recolored into `context`. `content` may be called with a different
    /// context than `context` (an offscreen copy in keep-hue mode).
    func draw(in context: CGContext, rect: CGRect, content: (CGContext) -> Void) {
        let space = Self.rgbSpace(of: context)
        let light = Self.components(self.light, in: space)
        let dark = Self.components(self.dark, in: space)
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        guard keepHue, let original = OffscreenCopy(of: context, rect: rect, content: content) else {
            content(context)
            Self.fill(context, rect, space, Self.rampSteps(light: light, dark: dark))
            return
        }
        let lumL = Self.luminance(light), lumD = Self.luminance(dark)
        original.draw(in: context)
        Self.fill(context, rect, space, Self.rampSteps(light: [lumL, lumL, lumL], dark: [lumD, lumD, lumD]))
        context.setBlendMode(.color)
        original.draw(in: context)
        Self.fill(context, rect, space, Self.tintSteps(light: light, dark: dark))
    }

    // MARK: Steps

    typealias Step = (mode: CGBlendMode, color: [CGFloat])

    private static func rampSteps(light: [CGFloat], dark: [CGFloat]) -> [Step] {
        let a = zip(light, dark).map { min($0, $1) }
        let b = zip(light, dark).map { max($0, $1) }
        let invert = zip(light, dark).map { $0 < $1 ? CGFloat(1) : 0 }
        let scale = zip(a, b).map { a, b in a < 1 ? (b - a) / (1 - a) : 1 }
        return [(.saturation, [0.5, 0.5, 0.5])]
            + steps([(.difference, invert, 0), (.multiply, scale, 1), (.screen, a, 0)])
    }

    /// Maps neutral gray k = Lum(D) + (Lum(L) - Lum(D))·v onto D + (L - D)·v.
    private static func tintSteps(light: [CGFloat], dark: [CGFloat]) -> [Step] {
        let lumL = luminance(light), lumD = luminance(dark)
        guard abs(lumL - lumD) > 1e-3 else { return [] }
        var beta = zip(light, dark).map { ($0 - $1) / (lumL - lumD) }
        var alpha = (0..<3).map { dark[$0] - beta[$0] * lumD }
        // Negative slope: invert first, out = (α + β) + (-β)(1 - k).
        let invert = beta.map { $0 < 0 ? CGFloat(1) : 0 }
        for c in 0..<3 where beta[c] < 0 {
            alpha[c] += beta[c]
            beta[c] = -beta[c]
        }
        // Subtract before scaling up and add after, so clipping only happens
        // where the exact result is out of range anyway.
        let subtract = (0..<3).map { c in alpha[c] < 0 && beta[c] > 0 ? 1 + alpha[c] / beta[c] : 1 }
        let dodge = beta.map { $0 > 1 ? 1 - 1 / $0 : 0 }
        let multiply = beta.map { min($0, 1) }
        let add = alpha.map { max($0, 0) }
        return steps([(.difference, invert, 0), (.plusDarker, subtract, 1), (.colorDodge, dodge, 0),
                      (.multiply, multiply, 1), (.plusLighter, add, 0)])
    }

    /// Drops steps whose fill is the mode's identity on every channel.
    private static func steps(_ list: [(CGBlendMode, [CGFloat], CGFloat)]) -> [Step] {
        list.filter { _, color, identity in color.contains { abs($0 - identity) > 0.5 / 255 } }
            .map { ($0.0, $0.1) }
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, _ space: CGColorSpace, _ steps: [Step]) {
        for step in steps {
            context.setBlendMode(step.mode)
            context.setFillColor(CGColor(colorSpace: space, components: step.color.map { min(max($0, 0), 1) } + [1])!)
            context.fill(rect)
        }
    }

    // MARK: Color

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Blend modes work on the destination's components, so the endpoints are
    /// converted into the destination's RGB space first.
    private static func rgbSpace(of context: CGContext) -> CGColorSpace {
        guard let space = context.colorSpace, space.model == .rgb else { return sRGB }
        return space
    }

    private static func components(_ rgb: [CGFloat], in space: CGColorSpace) -> [CGFloat] {
        guard space != sRGB,
              let converted = CGColor(colorSpace: sRGB, components: rgb + [1])?
                .converted(to: space, intent: .relativeColorimetric, options: nil),
              let c = converted.components, c.count >= 3 else { return rgb }
        return Array(c.prefix(3))
    }

    /// The luminosity CoreGraphics' non-separable blend modes use.
    private static func luminance(_ c: [CGFloat]) -> CGFloat {
        0.3 * c[0] + 0.59 * c[1] + 0.11 * c[2]
    }
}

/// A device-resolution bitmap of what `content` draws inside `rect`, limited
/// to the context's clip (one tile), so keep-hue can composite the page twice
/// while rendering it once. A plain bitmap context rather than a CGLayer:
/// PDFView's tile contexts are display-list contexts, and a bitmap behaves
/// the same under every kind of destination.
private struct OffscreenCopy {
    let image: CGImage
    let deviceRect: CGRect
    let transform: CGAffineTransform

    init?(of context: CGContext, rect: CGRect, content: (CGContext) -> Void) {
        transform = context.userSpaceToDeviceSpaceTransform
        deviceRect = context.boundingBoxOfClipPath.intersection(rect).applying(transform).integral
        guard !deviceRect.isEmpty,
              let bitmap = CGContext(data: nil, width: Int(deviceRect.width), height: Int(deviceRect.height),
                                     bitsPerComponent: 8, bytesPerRow: 0,
                                     space: context.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        bitmap.translateBy(x: -deviceRect.minX, y: -deviceRect.minY)
        bitmap.concatenate(transform)
        content(bitmap)
        guard let image = bitmap.makeImage() else { return nil }
        self.image = image
    }

    func draw(in context: CGContext) {
        context.saveGState()
        context.concatenate(transform.inverted())
        context.draw(image, in: deviceRect)
        context.restoreGState()
    }
}

/// Draws content with its lightness inverted but hue and saturation kept
/// (black becomes white, navy becomes light blue), alpha unchanged. Renders
/// `content` once into a device-resolution bitmap the size of `rect` within
/// the current clip, then: `.difference` with white inverts the colours
/// (same saturation, lightness 1 - L, opposite hue), `.hue` with the
/// original puts the original hue back, and `.destinationIn` with the
/// original restores its coverage.
enum LightnessInversion {
    static func draw(in context: CGContext, rect: CGRect, content: (CGContext) -> Void) {
        let transform = context.userSpaceToDeviceSpaceTransform
        let deviceRect = context.boundingBoxOfClipPath.intersection(rect).applying(transform).integral
        let space = context.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        func bitmap() -> CGContext? {
            CGContext(data: nil, width: Int(deviceRect.width), height: Int(deviceRect.height),
                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        }
        guard !deviceRect.isEmpty, deviceRect.width * deviceRect.height < 64_000_000,
              let source = bitmap(), let result = bitmap() else {
            content(context)
            return
        }
        source.translateBy(x: -deviceRect.minX, y: -deviceRect.minY)
        source.concatenate(transform)
        content(source)
        guard let original = source.makeImage() else {
            content(context)
            return
        }
        let full = CGRect(x: 0, y: 0, width: deviceRect.width, height: deviceRect.height)
        result.draw(original, in: full)
        result.setBlendMode(.difference)
        result.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1]) ?? CGColor(gray: 1, alpha: 1))
        result.fill(full)
        result.setBlendMode(.destinationIn)
        result.draw(original, in: full)
        result.setBlendMode(.hue)
        result.draw(original, in: full)
        result.setBlendMode(.destinationIn)
        result.draw(original, in: full)
        guard let inverted = result.makeImage() else {
            content(context)
            return
        }
        context.saveGState()
        context.concatenate(transform.inverted())
        context.draw(inverted, in: deviceRect)
        context.restoreGState()
    }
}
