import AppKit

/// Turning drawn strokes or an imported picture into a transparent signature
/// image (dark ink, alpha channel, cropped to the ink).
enum SignatureImaging {
    static let ink = (r: UInt8(14), g: UInt8(18), b: UInt8(48))
    static let maxDimension = 900

    /// Premultiplied RGBA from per-pixel alpha, cropped to the ink with a
    /// small margin. Nil when there is no ink.
    static func makeImage(alpha: [UInt8], width: Int, height: Int) -> CGImage? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where alpha[y * width + x] > 24 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let margin = 4
        minX = max(0, minX - margin); minY = max(0, minY - margin)
        maxX = min(width - 1, maxX + margin); maxY = min(height - 1, maxY + margin)
        let w = maxX - minX + 1, h = maxY - minY + 1
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let a = Int(alpha[(y + minY) * width + x + minX])
                let o = (y * w + x) * 4
                pixels[o] = UInt8(Int(ink.r) * a / 255)
                pixels[o + 1] = UInt8(Int(ink.g) * a / 255)
                pixels[o + 2] = UInt8(Int(ink.b) * a / 255)
                pixels[o + 3] = UInt8(a)
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Like Preview's import: paper becomes transparent, ink stays. Uses the
    /// image's own alpha when it has any, otherwise an Otsu threshold on
    /// luminance with a soft edge.
    static func fromPicture(_ source: CGImage) -> CGImage? {
        let scale = min(1, Double(maxDimension) / Double(max(source.width, source.height)))
        let w = max(1, Int((Double(source.width) * scale).rounded()))
        let h = max(1, Int((Double(source.height) * scale).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drew = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        let hasAlpha = stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] < 250 }
        var alpha = [UInt8](repeating: 0, count: w * h)
        // Luminance over white (premultiplied: add the missing coverage as white).
        func luminance(_ i: Int) -> Double {
            let a = Double(rgba[i * 4 + 3]) / 255
            let r = Double(rgba[i * 4]) / 255 + (1 - a)
            let g = Double(rgba[i * 4 + 1]) / 255 + (1 - a)
            let b = Double(rgba[i * 4 + 2]) / 255 + (1 - a)
            return 0.299 * r + 0.587 * g + 0.114 * b
        }
        if hasAlpha {
            for i in 0..<w * h { alpha[i] = rgba[i * 4 + 3] }
        } else {
            var histogram = [Int](repeating: 0, count: 256)
            for i in 0..<w * h { histogram[min(255, Int(luminance(i) * 255))] += 1 }
            let t = Double(otsu(histogram))
            let soft = 28.0
            for i in 0..<w * h {
                let l = luminance(i) * 255
                // Fully ink below t - soft, fully paper above t + soft... biased
                // toward keeping thin pen strokes.
                let v = (t + soft * 0.5 - l) / soft
                alpha[i] = UInt8(max(0, min(1, v)) * 255)
            }
        }
        return makeImage(alpha: alpha, width: w, height: h)
    }

    static func otsu(_ histogram: [Int]) -> Int {
        let total = histogram.reduce(0, +)
        guard total > 0 else { return 128 }
        var sum = 0.0
        for (i, n) in histogram.enumerated() { sum += Double(i * n) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            wB += histogram[t]
            if wB == 0 { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * histogram[t])
            let mB = sumB / Double(wB), mF = (sum - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return threshold
    }
}

/// Smoothed strokes: points are filtered and drawn as quadratic curves
/// through midpoints, with pen width following speed a little.
struct InkStroke {
    var points: [CGPoint] = []
    var times: [TimeInterval] = []

    mutating func add(_ p: CGPoint, at time: TimeInterval) {
        if let last = points.last, hypot(p.x - last.x, p.y - last.y) < 0.8 { return }
        // Light low-pass filter against hand/trackpad jitter.
        if let last = points.last {
            points.append(CGPoint(x: last.x * 0.3 + p.x * 0.7, y: last.y * 0.3 + p.y * 0.7))
        } else {
            points.append(p)
        }
        times.append(time)
    }

    func path() -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        if points.count < 3 {
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            return path
        }
        path.move(to: first)
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: i == 1 ? mid : mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}
