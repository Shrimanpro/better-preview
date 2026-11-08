import AppKit
import BPCore
import PDFKit

/// Offscreen self-checks for recolor and trim. `BP_SELFTEST=recolor` or
/// `BP_SELFTEST=trim` (or `all`) prints PASS/FAIL lines to stderr, writes
/// preview PNGs / test PDFs under build/tmp/, and exits (status 1 on failure).
/// `BP_SELFTEST=markup|pages|forms` runs a feature self-test instead (see
/// `featureRequested`); this one then does nothing.
@MainActor
enum PDFSelfTest {
    private static var hasRun = false

    static func runIfRequested() {
        guard !hasRun, let which = ProcessInfo.processInfo.environment["BP_SELFTEST"],
              ["recolor", "trim", "outline", "all"].contains(which) else { return }
        hasRun = true
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var ok = true
        if which == "recolor" || which == "all" { ok = recolorChecks() && ok }
        if which == "trim" || which == "all" { ok = trimChecks() && ok }
        if which == "outline" || which == "all" { ok = outlineChecks() && ok }
        log(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        exit(ok ? 0 : 1)
    }

    /// Whether a feature self-test is requested: `BP_SELFTEST=<name>` or its
    /// own variable (e.g. `BP_MARKUP_SELFTEST=1`).
    static func featureRequested(_ name: String, variable: String) -> Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["BP_SELFTEST"] == name || ![nil, "", "0"].contains(environment[variable])
    }

    static let outputDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tmp", isDirectory: true)

    static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    @discardableResult
    static func check(_ condition: Bool, _ message: String) -> Bool {
        log((condition ? "PASS " : "FAIL ") + message)
        return condition
    }

    // MARK: Recolor

    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Black, white, 50% gray and red patches, 100 x 100 pt each, in a row.
    private static let patches: [[CGFloat]] = [[0, 0, 0], [1, 1, 1], [0.5, 0.5, 0.5], [1, 0, 0]]

    private static func recolorChecks() -> Bool {
        var ok = true
        let document = patchDocument()
        let page = document.page(at: 0) as! RecolorPage
        for name in ["catppuccin-mocha", "gruvbox-light", "catppuccin-latte", "nord"] {
            guard let theme = ThemeRegistry.builtin[name] else { continue }
            let light = rgb(theme.recolorLightColor), dark = rgb(theme.recolorDarkColor)
            for keepHue in [false, true] {
                // Also like a PDFView tile: 2x, flipped, clipped to part of the page.
                for tile in [false, true] {
                let pixels = render(page, Recolor(theme: theme, keepHue: keepHue), tile: tile)
                let label = "\(name)\(keepHue ? " keephue" : "")\(tile ? " tile" : "")"
                for (i, input) in patches.enumerated() where keepHue == false || i < 3 {
                    // Plain mode is monochrome: colored input maps by luminance.
                    let v = 0.3 * input[0] + 0.59 * input[1] + 0.11 * input[2]
                    let expected = (0..<3).map { dark[$0] + (light[$0] - dark[$0]) * v }
                    let error = zip(pixels[i], expected).map { abs($0 - $1) }.max()! * 255
                    ok = check(error <= (keepHue ? 3 : 2), "recolor \(label) patch \(input): got \(hex(pixels[i])) expected \(hex(expected)) error \(String(format: "%.2f", error))/255") && ok
                }
                if keepHue {
                    // Red stays red: hue within a few degrees, clearly saturated.
                    let (hue, saturation) = hueSaturation(pixels[3])
                    let hueError = min(hue, 360 - hue)
                    ok = check(hueError < 12 && saturation > 0.3, "recolor \(label) red keeps hue: got \(hex(pixels[3])) hue \(Int(hue)) sat \(String(format: "%.2f", saturation))") && ok
                }
                }
            }
        }
        ok = check(render(page, nil)[2].allSatisfy { abs($0 - 0.5) < 2.0 / 255 }, "recolor off draws the original") && ok
        writePreviews()
        return ok
    }

    private static func patchDocument() -> BPDocument {
        let data = makePDF(size: CGSize(width: 400, height: 100)) { context in
            for (i, color) in patches.enumerated() {
                context.setFillColor(CGColor(colorSpace: sRGB, components: color + [1])!)
                context.fill(CGRect(x: i * 100, y: 0, width: 100, height: 100))
            }
        }
        return BPDocument(data: data)!
    }

    /// Draws the page at 1 px/pt into an sRGB bitmap; returns the center
    /// pixel of each patch.
    private static func render(_ page: RecolorPage, _ recolor: Recolor?, tile: Bool = false) -> [[CGFloat]] {
        (page.document as! BPDocument).renderState.recolor = recolor
        let scale = tile ? 2 : 1
        let context = CGContext(data: nil, width: 400 * scale, height: 100 * scale, bitsPerComponent: 8,
                                bytesPerRow: 1600 * scale, space: sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if tile {
            context.translateBy(x: 0, y: 200)
            context.scaleBy(x: 2, y: -2)
            context.clip(to: CGRect(x: 0, y: 10, width: 400, height: 80))
        }
        page.draw(with: .mediaBox, to: context)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        return patches.indices.map { i in
            let offset = (50 * scale * 400 * scale + (i * 100 + 50) * scale) * 4
            return (0..<3).map { CGFloat(data[offset + $0]) / 255 }
        }
    }

    /// Recolored thumbnails of long.pdf and of a colored test page, to look at.
    private static func writePreviews() {
        let colored = makePDF(size: CGSize(width: 300, height: 200)) { context in
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            let colors: [[CGFloat]] = [[1, 0, 0], [0, 0.6, 0], [0, 0, 1], [1, 0.8, 0], [0, 0, 0], [0.5, 0.5, 0.5]]
            for (i, color) in colors.enumerated() {
                context.setFillColor(CGColor(colorSpace: sRGB, components: color + [1])!)
                context.fill(CGRect(x: 20 + i * 45, y: 110, width: 35, height: 70))
            }
            let text = NSAttributedString(string: "Recolor keep-hue test", attributes: [
                .font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 20, y: 50)
            CTLineDraw(line, context)
        }
        let long = BPDocument(url: URL(fileURLWithPath: "build/test-assets/long.pdf"))
        for (name, keepHue) in [("catppuccin-mocha", false), ("gruvbox-light", false), ("catppuccin-mocha", true), ("gruvbox-light", true)] {
            let theme = ThemeRegistry.builtin[name]!
            let suffix = "\(name)\(keepHue ? "-keephue" : "")"
            for (document, stem) in [(BPDocument(data: colored), "colored"), (long, "long")] {
                guard let document, let page = document.page(at: 0) else { continue }
                document.renderState.recolor = Recolor(theme: theme, keepHue: keepHue)
                let image = page.renderedThumbnail(of: CGSize(width: 600, height: 600), for: .cropBox, scale: 1)
                document.renderState.recolor = nil
                guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?
                    .representation(using: .png, properties: [:]) else { continue }
                try? png.write(to: outputDirectory.appendingPathComponent("recolor-\(stem)-\(suffix).png"))
            }
        }
    }

    private static func rgb(_ c: RGBA) -> [CGFloat] { [c.r, c.g, c.b] }

    private static func hex(_ c: [CGFloat]) -> String {
        "#" + c.map { String(format: "%02x", Int(($0 * 255).rounded())) }.joined()
    }

    private static func hueSaturation(_ c: [CGFloat]) -> (CGFloat, CGFloat) {
        let color = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        return (color.hueComponent * 360, color.saturationComponent)
    }

    // MARK: Trim

    /// Letter pages with known content: even pages one rectangle, odd pages
    /// another (alternating book margins), a near-empty title-like page, an
    /// empty page, and a page on a noisy gray "scan" background.
    private static let pageSize = CGSize(width: 612, height: 792)
    private static let evenContent = CGRect(x: 150, y: 200, width: 300, height: 400)
    private static let oddContent = CGRect(x: 120, y: 180, width: 320, height: 420)
    private static let titleContent = CGRect(x: 250, y: 500, width: 100, height: 30)

    private static func trimContent(page: Int) -> CGRect? {
        switch page {
        case 4: return titleContent
        case 6: return nil
        default: return page % 2 == 0 ? evenContent : oddContent
        }
    }

    private static func trimChecks() -> Bool {
        let data = makePDF(sizes: Array(repeating: pageSize, count: 9)) { context, page in
            if page == 8 {
                // Scan-like: off-white paper with noise.
                var generator = SystemRandomNumberGenerator()
                context.setFillColor(gray: 0.92, alpha: 1)
                context.fill(CGRect(origin: .zero, size: pageSize))
                for _ in 0..<4000 {
                    let gray = 0.92 + CGFloat.random(in: -0.08...0.06, using: &generator)
                    context.setFillColor(gray: gray, alpha: 1)
                    context.fill(CGRect(x: .random(in: 0..<612, using: &generator),
                                        y: .random(in: 0..<792, using: &generator), width: 2, height: 2))
                }
            }
            guard let content = trimContent(page: page) else { return }
            // Text-like lines filling the content rectangle exactly.
            context.setFillColor(gray: 0, alpha: 1)
            var y = content.maxY - 10
            while y >= content.minY {
                context.fill(CGRect(x: content.minX, y: y, width: content.width, height: min(10, y - content.minY + 10)))
                y -= 18
            }
            context.fill(CGRect(x: content.minX, y: content.minY, width: content.width * 0.6, height: 8))
        }
        let url = outputDirectory.appendingPathComponent("trim-test.pdf")
        try? data.write(to: url)
        guard let document = BPDocument(url: url) else { return check(false, "trim test PDF opens") }

        var ok = true
        for index in 0..<document.pageCount {
            let page = document.page(at: index)!
            let found = ContentDetector.contentBox(of: page.pageRef!, in: page.bounds(for: .cropBox))
            let expected = trimContent(page: index)
            let error = boxError(found, expected)
            ok = check(error <= 4, "trim detect page \(index + 1): found \(describe(found)) expected \(describe(expected)) error \(String(format: "%.1f", error))pt") && ok
        }

        let trimmer = MarginTrimmer()
        trimmer.padding = 6
        trimmer.start(document: document, priority: [0])
        let expectedEven = CGRect(x: 300 - 166, y: 400 - 216, width: 332, height: 432)
        let expectedOdd = CGRect(x: 280 - 166, y: 390 - 216, width: 332, height: 432)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, document.page(at: 7)!.bounds(for: .cropBox) == CGRect(origin: .zero, size: pageSize) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))  // let the full pass finish
        for index in 0..<document.pageCount {
            let crop = document.page(at: index)!.bounds(for: .cropBox)
            let expected = index % 2 == 0 ? expectedEven : expectedOdd
            ok = check(boxError(crop, expected) <= 4, "trim crop page \(index + 1): \(describe(crop)) expected \(describe(expected))") && ok
        }
        let full = CGRect(origin: .zero, size: pageSize)
        let saved = trimmer.withOriginalBoxes { document.dataRepresentation() }.flatMap(PDFDocument.init(data:))
        ok = check(saved.map { copy in (0..<copy.pageCount).allSatisfy { copy.page(at: $0)!.bounds(for: .cropBox) == full } } == true,
                   "trim export guard writes the original crop boxes") && ok
        ok = check(document.page(at: 1)!.bounds(for: .cropBox) != full, "trim crop is back after the export guard") && ok
        trimmer.stop()
        ok = check((0..<document.pageCount).allSatisfy { document.page(at: $0)!.bounds(for: .cropBox) == full },
                   "trim off restores every crop box exactly") && ok
        // Freed pages leave no entry a new page could inherit (state is
        // keyed weakly by the page object, not its address).
        autoreleasepool { document.removePage(at: 0) }
        let fresh = PDFPage()
        fresh.setBounds(CGRect(x: 0, y: 0, width: 200, height: 100), for: .cropBox)
        document.insert(fresh, at: 0)
        trimmer.start(document: document, priority: [0])
        ok = check(trimmer.originalBox(of: fresh) == CGRect(x: 0, y: 0, width: 200, height: 100),
                   "trim: a newly inserted page keeps its own original box") && ok
        trimmer.stop()
        ok = check(fresh.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 200, height: 100),
                   "trim off leaves the new page's box alone") && ok
        return ok
    }

    private static func boxError(_ a: CGRect?, _ b: CGRect?) -> CGFloat {
        guard let a, let b else { return a == nil && b == nil ? 0 : .infinity }
        return max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.maxX - b.maxX), abs(a.maxY - b.maxY))
    }

    private static func describe(_ r: CGRect?) -> String {
        guard let r else { return "empty" }
        return String(format: "(%.0f %.0f %.0f %.0f)", r.minX, r.minY, r.width, r.height)
    }

    // MARK: Outline

    /// PDFKit does not write outlines it did not read, so the outline is
    /// built on the open document of a real controller.
    private static func outlineChecks() -> Bool {
        let url = outputDirectory.appendingPathComponent("outline-test.pdf")
        try? makePDF(size: pageSize, pages: 4) { _ in }.write(to: url)
        guard let controller = PDFDocumentController(url: url), let document = controller.document else {
            return check(false, "outline test PDF opens")
        }
        let root = PDFOutline()
        document.outlineRoot = root
        let unspecified = CGFloat(kPDFDestinationUnspecifiedValue)
        let specs: [(String, Int, CGPoint, Int)] = [  // title, page, point, parent (-1 = root)
            ("Chapter 1", 0, CGPoint(x: 0, y: 792), -1),
            ("Section 1.1", 1, CGPoint(x: 61.2, y: 396), 0),
            ("Chapter 2", 2, CGPoint(x: unspecified, y: unspecified), -1),
        ]
        var items: [PDFOutline] = []
        for (title, page, point, parent) in specs {
            let item = PDFOutline()
            item.label = title
            item.destination = PDFDestination(page: document.page(at: page)!, at: point)
            let container = parent < 0 ? root : items[parent]
            container.insertChild(item, at: container.numberOfChildren)
            items.append(item)
        }
        let got = controller.outline.map {
            "\($0.title)|\($0.level)|\($0.position.page)|\(String(format: "%.2f,%.2f", $0.position.x, $0.position.y))"
        }
        let expected = ["Chapter 1|0|0|0.00,0.00", "Section 1.1|1|1|0.10,0.50", "Chapter 2|0|2|0.00,0.00"]
        return check(got == expected, "outline flattened: \(got)")
    }

    // MARK: Helpers

    static func makePDF(size: CGSize, pages: Int = 1, draw: (CGContext) -> Void) -> Data {
        makePDF(sizes: Array(repeating: size, count: pages)) { context, _ in draw(context) }
    }

    static func makePDF(sizes: [CGSize], draw: (CGContext, Int) -> Void) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: sizes.first ?? .zero)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        for (index, size) in sizes.enumerated() {
            var pageBox = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &pageBox)
            draw(context, index)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
