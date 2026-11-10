import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writes a CGImage to disk in PNG, JPEG, HEIC, TIFF, PDF or any other format
/// ImageIO can encode.
enum ImageEncoder {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    /// Formats offered in the export panel.
    static let exportFormats: [(name: String, type: UTType)] = [
        ("PNG", .png), ("JPEG", .jpeg), ("HEIC", .heic), ("TIFF", .tiff), ("PDF", .pdf),
    ]

    static func type(for url: URL) -> UTType? {
        UTType(filenameExtension: url.pathExtension.lowercased())
    }

    static func supportsQuality(_ type: UTType) -> Bool {
        type.conforms(to: .jpeg) || type.conforms(to: .heic)
    }

    /// Every frame of a multi-frame file (TIFF, GIF, HEIC sequence, ...):
    /// frames in `edits` are written from their edited bitmap, the others
    /// copied unchanged from `source`. `index` is the frame `image` replaces.
    struct FrameSet {
        var source: CGImageSource
        var index: Int
        var edits: [Int: CGImage]
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double, dpi: CGSize?,
                      metadata: [CFString: Any] = [:], frames: FrameSet? = nil) throws {
        if type.conforms(to: .pdf) { return try writePDF(image, to: url, dpi: dpi) }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let noAlpha = type.conforms(to: .jpeg) || type.conforms(to: .bmp)
        let source = (hasAlpha && noAlpha ? ImageOps.flattened(image) : nil) ?? image
        // Write to a temp file in the same folder, then swap in: a failed
        // encode never destroys the original.
        let temp = url.deletingLastPathComponent().appendingPathComponent(".bp-\(UUID().uuidString).tmp")
        let count = frames.map { CGImageSourceGetCount($0.source) } ?? 1
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, type.identifier as CFString, count, nil) else {
            throw Failure(errorDescription: "Cannot write \(type.preferredFilenameExtension ?? type.identifier) files")
        }
        let properties = cleaned(metadata, type: type, quality: quality, dpi: dpi)
        if let frames {
            // File-level properties (e.g. a GIF's loop count).
            if let file = CGImageSourceCopyProperties(frames.source, nil) as? [CFString: Any],
               let gif = file[kCGImagePropertyGIFDictionary] {
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: gif] as CFDictionary)
            }
            for index in 0..<count {
                if index == frames.index {
                    CGImageDestinationAddImage(destination, source, properties as CFDictionary)
                } else if let edited = frames.edits[index] {
                    let own = CGImageSourceCopyPropertiesAtIndex(frames.source, index, nil) as? [CFString: Any] ?? [:]
                    let flat = (noAlpha ? ImageOps.flattened(edited) : nil) ?? edited
                    CGImageDestinationAddImage(destination, flat,
                                               cleaned(own, type: type, quality: quality, dpi: nil) as CFDictionary)
                } else {
                    CGImageDestinationAddImageFromSource(destination, frames.source, index, nil)
                }
            }
        } else {
            CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: temp)
            throw Failure(errorDescription: "Encoding failed")
        }
        try swap(temp, into: url)
    }

    /// Frame metadata for a re-encoded (already oriented) bitmap.
    private static func cleaned(_ metadata: [CFString: Any], type: UTType, quality: Double,
                                dpi: CGSize?) -> [CFString: Any] {
        var properties = metadata
        for key in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight] {
            properties[key] = nil
        }
        for key in [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary] {
            if var sub = properties[key] as? [CFString: Any] {
                sub[kCGImagePropertyTIFFOrientation] = nil
                sub[kCGImagePropertyExifPixelXDimension] = nil
                sub[kCGImagePropertyExifPixelYDimension] = nil
                properties[key] = sub
            }
        }
        if supportsQuality(type) { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi.width
            properties[kCGImagePropertyDPIHeight] = dpi.height
        }
        return properties
    }

    private static func writePDF(_ image: CGImage, to url: URL, dpi: CGSize?) throws {
        let scale = dpi.map { CGSize(width: 72 / max($0.width, 1), height: 72 / max($0.height, 1)) } ?? CGSize(width: 1, height: 1)
        var box = CGRect(x: 0, y: 0, width: CGFloat(image.width) * scale.width, height: CGFloat(image.height) * scale.height)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".bp-\(UUID().uuidString).tmp")
        guard let context = CGContext(temp as CFURL, mediaBox: &box, nil) else {
            throw Failure(errorDescription: "Cannot create PDF")
        }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        try swap(temp, into: url)
    }

    private static func swap(_ temp: URL, into url: URL) throws {
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}
