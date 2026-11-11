@preconcurrency import CoreGraphics
import CoreText
import Foundation
import Vision

/// Recognizes the text of one PDF page and rebuilds the page with an
/// invisible text layer. Pure functions on CoreGraphics / Vision objects; safe
/// on any thread (the CGPDFPage is only read).
enum OCREngine {
    struct Result {
        /// One-page PDF: the original content plus invisible text (render
        /// mode 3). Same media and crop box as the source page.
        let pdf: Data
        let lineCount: Int
        let text: String
    }

    /// Longest side of the image handed to Vision, in pixels.
    static let targetPixels: CGFloat = 3000

    /// `languages`: BCP-47 codes; empty = automatic language detection.
    /// Returns nil when nothing was recognized or rendering failed.
    static func recognize(page: CGPDFPage, languages: [String], isCancelled: () -> Bool = { false }) -> Result? {
        autoreleasepool {
            let crop = page.getBoxRect(.cropBox)
            guard crop.width > 1, crop.height > 1 else { return nil }
            let rotation = page.rotationAngle
            let upright = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
            let scale = min(targetPixels / max(upright.width, upright.height), 4)
            let width = max(1, Int((upright.width * scale).rounded()))
            let height = max(1, Int((upright.height * scale).rounded()))
            // Page space -> upright space (points), honouring /Rotate.
            let toUpright = page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: upright),
                                                     rotate: 0, preserveAspectRatio: true)

            guard let image = render(page: page, transform: toUpright, scale: scale, width: width, height: height),
                  !isCancelled() else { return nil }

            let lines = observe(image, languages: languages, size: upright)
            guard !lines.isEmpty, !isCancelled() else { return nil }
            guard let data = buildPage(page, lines: lines, toUpright: toUpright) else { return nil }
            return Result(pdf: data, lineCount: lines.count, text: lines.map(\.text).joined(separator: "\n"))
        }
    }

    // MARK: Rendering

    private static func render(page: CGPDFPage, transform: CGAffineTransform, scale: CGFloat,
                               width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(transform)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    // MARK: Vision

    struct Line {
        let text: String
        /// In upright page points, origin bottom-left.
        let box: CGRect
    }

    private static func observe(_ image: CGImage, languages: [String], size: CGSize) -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let n = observation.boundingBox
            lines.append(Line(text: text, box: CGRect(x: n.minX * size.width, y: n.minY * size.height,
                                                      width: n.width * size.width, height: n.height * size.height)))
        }
        return lines
    }

    /// Languages from the `ocr-languages` option: comma or space separated.
    static func languages(from option: String) -> [String] {
        option.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
    }

    // First-run cost (measured on macOS 27, M5): the first accurate
    // recognition in a new or rebuilt app binary waits ~12-25 s while
    // ANECompilerService compiles Vision's text models for the Neural Engine
    // (one core at 100%), whatever the language settings or compute device
    // (even CPU-only requests trigger it); afterwards they are cached and a
    // page takes ~0.15 s. Only `.fast` avoids it, at a clear loss of
    // accuracy. Nothing in the app can skip it, so the feature tells the user
    // when the first page is slow instead of looking stuck.

    // MARK: Page rebuild

    private static func buildPage(_ page: CGPDFPage, lines: [Line], toUpright: CGAffineTransform) -> Data? {
        let media = page.getBoxRect(.mediaBox)
        let crop = page.getBoxRect(.cropBox)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { return nil }
        var box = media
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        var cropRect = crop
        let cropData = Data(bytes: &cropRect, count: MemoryLayout<CGRect>.size) as CFData
        context.beginPDFPage([kCGPDFContextCropBox: cropData] as CFDictionary)
        context.drawPDFPage(page)

        let fromUpright = toUpright.inverted()
        let font = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font)
        let descent = CTFontGetDescent(font)
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let size = line.box.height / lineHeight
            guard size > 0.5 else { continue }
            let attributed = NSAttributedString(string: line.text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, size, nil),
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
            guard natural > 0.1 else { continue }
            // Baseline start and direction in page space.
            let origin = CGPoint(x: line.box.minX, y: line.box.minY + descent * size).applying(fromUpright)
            let along = CGPoint(x: line.box.minX + 1, y: line.box.minY + descent * size).applying(fromUpright)
            let angle = atan2(along.y - origin.y, along.x - origin.x)
            let stretch = line.box.width / natural
            var matrix = CGAffineTransform(translationX: origin.x, y: origin.y).rotated(by: angle)
            matrix = matrix.scaledBy(x: stretch, y: 1)
            context.textMatrix = matrix
            CTLineDraw(ctLine, context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}
