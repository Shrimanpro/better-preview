import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything the viewer (and the later editor) knows about the open image.
///
/// `image` is what was decoded first: the full image, or a screen-sized
/// downsample for huge files. `fullResolution` is only set while a huge image
/// is zoomed past what the downsample resolves. `pendingEdit` will hold the
/// edited bitmap once editing exists; it always wins for display.
struct ImageModel {
    var sourceType: UTType?
    /// Oriented size of the current frame in pixels.
    var pixelSize: CGSize
    /// Dots per inch as stored in the file, if any.
    var dpi: CGSize?
    var frameCount: Int
    var image: CGImage?
    var fullResolution: CGImage?
    var pendingEdit: CGImage?

    init(info: ImageLoader.Info) {
        sourceType = info.sourceType
        pixelSize = info.pixelSize
        dpi = info.dpi
        frameCount = info.frameCount
    }

    var displayImage: CGImage? { pendingEdit ?? fullResolution ?? image }

    /// True when `image` has fewer pixels than the file.
    var isDownsampled: Bool {
        guard let image else { return false }
        return Double(image.width) < pixelSize.width - 0.5
    }

    /// Size at the file's own resolution in points (72 per inch), for printing.
    var physicalSize: CGSize {
        guard let dpi, dpi.width > 0, dpi.height > 0 else { return pixelSize }
        return CGSize(width: pixelSize.width * 72 / dpi.width, height: pixelSize.height * 72 / dpi.height)
    }
}

/// ImageIO decoding. Everything here is safe to call off the main thread.
enum ImageLoader {
    struct Info {
        var sourceType: UTType?
        var pixelSize: CGSize
        var dpi: CGSize?
        var frameCount: Int
    }

    struct Loaded {
        var info: Info
        var image: CGImage
    }

    /// Images above this many megapixels are shown downsampled first.
    static let hugeMegapixels = 40.0

    static func source(_ url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
    }

    /// Header-only read of one frame. Nil if ImageIO cannot decode the file.
    static func probe(_ url: URL, index: Int = 0) -> Info? {
        source(url).flatMap { info(of: $0, index: index) }
    }

    static func info(of source: CGImageSource, index: Int) -> Info? {
        let count = CGImageSourceGetCount(source)
        guard index >= 0, index < count,
              let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0
        else { return nil }
        let swapped = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        var dpi: CGSize?
        if let dx = props[kCGImagePropertyDPIWidth] as? Double,
           let dy = props[kCGImagePropertyDPIHeight] as? Double, dx > 0, dy > 0 {
            dpi = swapped ? CGSize(width: dy, height: dx) : CGSize(width: dx, height: dy)
        }
        let type = CGImageSourceGetType(source).flatMap { UTType($0 as String) }
        return Info(sourceType: type, pixelSize: swapped ? CGSize(width: h, height: w) : CGSize(width: w, height: h),
                    dpi: dpi, frameCount: count)
    }

    /// Decodes one frame with EXIF orientation applied. Huge images come back
    /// downsampled to `displayMax` pixels on the long side unless `full`.
    static func load(_ url: URL, index: Int, displayMax: Int, full: Bool = false) -> Loaded? {
        guard let source = source(url), let info = info(of: source, index: index) else { return nil }
        let longest = Int(max(info.pixelSize.width, info.pixelSize.height))
        let megapixels = info.pixelSize.width * info.pixelSize.height / 1e6
        let limit = full || megapixels <= hugeMegapixels ? longest : min(displayMax, longest)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: limit,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            return nil
        }
        return Loaded(info: info, image: image)
    }
}
