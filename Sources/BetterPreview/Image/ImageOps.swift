import CoreGraphics

/// Pixel operations on CGImages. Every result owns its bitmap (a crop is a
/// copy, never a view into the parent), so dropping the source frees it.
enum ImageOps {
    /// A bitmap context for `width`×`height` in the image's own colour space
    /// and depth, keeping opacity as it was: RGB stays RGB (sRGB, Display
    /// P3, ...), opaque gray stays gray, other models become sRGB. Sources
    /// deeper than 8 bits per channel get 16-bit integer channels, floating
    /// point sources (HDR) 32-bit floats, so edits do not band or clip.
    static func context(width: Int, height: Int, like image: CGImage, forceOpaque: Bool = false) -> CGContext? {
        let opaque = forceOpaque || [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        var space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let gray = space.model == .monochrome && opaque
        if space.model != .rgb && !gray { space = CGColorSpace(name: CGColorSpace.sRGB)! }
        let isFloat = image.bitmapInfo.contains(.floatComponents)
        let bits = isFloat ? 32 : image.bitsPerComponent > 8 ? 16 : 8
        var info: UInt32 = gray ? CGImageAlphaInfo.none.rawValue
            : (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue
        if isFloat {
            info |= CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        } else if bits == 16 {
            info |= CGBitmapInfo.byteOrder16Little.rawValue
        }
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: bits, bytesPerRow: 0,
                                space: space, bitmapInfo: info)
            // Unsupported combination: fall back to 8-bit RGB in that space.
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: space.model == .rgb ? space : CGColorSpace(name: CGColorSpace.sRGB)!,
                         bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)
        context?.interpolationQuality = .high
        return context
    }

    static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(width: w, height: h, like: image) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(w), y: 0)
            ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(width: h, height: w, like: image) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// `rect` in pixels with a top-left origin, already clamped to the image.
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let w = Int(rect.width), h = Int(rect.height)
        guard w > 0, h > 0, let ctx = context(width: w, height: h, like: image) else { return nil }
        ctx.draw(image, in: CGRect(x: -rect.minX, y: -(CGFloat(image.height) - rect.maxY),
                                   width: CGFloat(image.width), height: CGFloat(image.height)))
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0, let ctx = context(width: width, height: height, like: image) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// Composites over white, for formats without alpha.
    static func flattened(_ image: CGImage) -> CGImage? {
        guard ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo),
              let ctx = context(width: image.width, height: image.height, like: image, forceOpaque: true)
        else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}
