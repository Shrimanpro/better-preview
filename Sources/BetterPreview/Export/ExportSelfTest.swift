import AppKit
import BPCore
import PDFKit

/// `BP_EXPORT_SELFTEST=1 BetterPreview <any pdf>`: builds test PDFs in
/// build/tmp/export-test, then drives the real export, save, unlock and print
/// paths: every format, reduce file size on an image-heavy PDF, encryption
/// round trip (locked on reopen, unlock, permissions), atomic-write failures,
/// and in-place / save-as saves not triggering the auto-reload. Prints
/// PASS/FAIL lines and `EXPORT SELFTEST PASS|FAIL`, then exits (1 on failure).
@MainActor
enum ExportSelfTest {
    private static var hasRun = false
    private static var ok = true
    private static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tmp/export-test", isDirectory: true)

    static func runIfRequested() {
        guard !hasRun, ProcessInfo.processInfo.environment["BP_EXPORT_SELFTEST"] == "1" else { return }
        hasRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                let passed = await run()
                log(passed ? "EXPORT SELFTEST PASS" : "EXPORT SELFTEST FAIL")
                exit(passed ? 0 : 1)
            }
        }
    }

    private static func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    private static func check(_ condition: Bool, _ message: String) {
        log((condition ? "PASS " : "FAIL ") + message)
        if !condition { ok = false }
    }

    private final class StubHost: DocumentHost {
        var options: Options { AppEnvironment.shared.options }
        var theme: Theme { AppEnvironment.shared.theme }
        var mode: Mode = .normal
        var messages: [(String, Bool)] = []
        var last: String { messages.last?.0 ?? "" }
        func setMode(_ mode: Mode) { self.mode = mode }
        func dispatch(_ invocation: ActionInvocation) {}
        func documentStatusDidChange() {}
        func showMessage(_ text: String, isError: Bool) { messages.append((text, isError)) }
        func recordJump(from position: DocumentPosition) {}
    }

    // MARK: Test documents

    /// Three letter pages of text.
    private static func makeTextPDF(at url: URL, pages: Int = 3) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSAttributedString(string: "Export test page \(page) ZEBRAFISH\(page)", attributes: [
                .font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black,
            ]).draw(at: CGPoint(x: 72, y: 700))
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Full-page photographic-ish bitmaps (smooth gradients plus noise) that
    /// compress badly as Flate and well as downsampled JPEG.
    private static func makeImagePDF(at url: URL) {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        let width = 1500, height = 1950
        var seed: UInt32 = 12345
        for page in 0..<2 {
            var pixels = [UInt8](repeating: 0, count: width * height * 3)
            for y in 0..<height {
                for x in 0..<width {
                    seed = seed &* 1664525 &+ 1013904223
                    let noise = Int(seed >> 29)
                    let i = (y * width + x) * 3
                    pixels[i] = UInt8(clamping: x * 255 / width + noise)
                    pixels[i + 1] = UInt8(clamping: y * 255 / height + noise + page * 20)
                    pixels[i + 2] = UInt8(clamping: (x + y) * 255 / (width + height) + noise)
                }
            }
            let provider = CGDataProvider(data: Data(pixels) as CFData)!
            let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24,
                                bytesPerRow: width * 3, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
                                shouldInterpolate: true, intent: .defaultIntent)!
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }

    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
    }

    private static func pixel(_ url: URL, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()),
              let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return nil }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    private static func pixelSize(_ url: URL) -> CGSize? {
        guard let rep = NSBitmapImageRep(data: (try? Data(contentsOf: url)) ?? Data()) else { return nil }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    private static func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Run

    private static func run() async -> Bool {
        let fm = FileManager.default
        try? fm.removeItem(at: directory)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        func path(_ name: String) -> URL { directory.appendingPathComponent(name) }
        func fresh(_ name: String, _ make: @MainActor (URL) -> Void = { makeTextPDF(at: $0) }) -> URL {
            let url = path(name)
            try? fm.removeItem(at: url)
            make(url)
            return url
        }

        // Argument parsing.
        do {
            let r = try ExportRequest.parse("out.png 150 current")
            check(r.options.format == .png && r.options.dpi == 150 && r.options.currentPageOnly && r.path == "out.png",
                  "export argument parsing (path, dpi, current)")
            let q = try ExportRequest.parse("\"my file.pdf\" reduce pw=abc owner=xyz noprint")
            check(q.path == "my file.pdf" && q.options.reduceSize && q.options.openPassword == "abc"
                  && q.options.ownerPassword == "xyz" && !q.options.allowPrinting, "export argument parsing (pdf options)")
            check((try? ExportRequest.parse("out.xyz")) == nil, "unknown export extension is an error")
            check((try? ExportRequest.parse("out.pdf png")) == nil, "format token contradicting the extension is an error")
            let numeric = try ExportRequest.parse("\"2024\" png")
            check(numeric.path == "2024.png" && numeric.options.format == .png && numeric.options.dpi == 144,
                  "quoted numeric file name is a path, not the dpi (\(numeric.path ?? "nil"))")
            let versioned = try ExportRequest.parse("notes.v2 png")
            check(versioned.path == "notes.v2.png", "unknown extension + format gets the format's extension")
            let invocation = try CommandParser.parse("export \"a b.png\" 72 current")
            let spaced = try ExportRequest.parse(invocation.action.argument)
            check(spaced.path == "a b.png" && spaced.options.dpi == 72, "typed :export \"a b.png\" keeps the space")
            check(CommandBar.containsPassword("export x.pdf pw=abc") && CommandBar.containsPassword("export x.pdf OWNER=z")
                  && !CommandBar.containsPassword("export x.pdf reduce"), "export passwords are kept out of the history")
            check((try? PDFExportOptions(format: .pdf, allowPrinting: false).validate()) == nil,
                  "restricting permissions without an owner password is refused")
        } catch {
            check(false, "argument parsing threw \(error)")
        }

        // Formats.
        let source = fresh("source.pdf")
        guard let controller = PDFDocumentController(url: source), let document = controller.document else {
            check(false, "source opens")
            return false
        }
        let host = StubHost()
        controller.host = host
        // A red square on page 1 to prove annotations are exported.
        let red = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 100, height: 100), forType: .square, withProperties: nil)
        red.color = .red
        red.interiorColor = .red
        document.page(at: 0)?.addAnnotation(red)
        // View-only state that must not leak into exports.
        controller.perform(ActionInvocation(.rotateCW))
        controller.perform(ActionInvocation(.toggleRecolor))

        controller.perform(ActionInvocation(.export, "all.pdf"))
        let all = PDFDocument(url: path("all.pdf"))
        check(all?.pageCount == 3, "export pdf keeps 3 pages (\(host.last))")
        check(all?.page(at: 0)?.rotation == 0, "export pdf has no view rotation")
        check(all?.string?.contains("ZEBRAFISH2") == true, "export pdf keeps text")
        controller.perform(ActionInvocation(.export, "all.pdf"))
        check(host.last.contains("exists"), "export refuses to replace an existing file: \(host.last)")
        controller.perform(ActionInvocation(.export, "all.pdf force"))
        check(host.last.hasPrefix("exported"), "export force replaces: \(host.last)")

        for (ext, type) in [("png", "PNG"), ("jpg", "JPEG"), ("tiff", "TIFF"), ("heic", "HEIC")] {
            controller.perform(ActionInvocation(.export, "pages.\(ext) 72"))
            let files = (1...3).map { path("pages-\($0).\(ext)") }
            check(files.allSatisfy { fileSize($0) > 0 }, "\(type): one file per page (\(host.last))")
            check(pixelSize(files[0]) == CGSize(width: 612, height: 792), "\(type): 72 dpi is 612x792, not rotated")
            if ext == "png" {
                let p = pixel(files[0], x: 150, y: 792 - 150)
                check(p.map { $0.r > 200 && $0.g < 60 } == true, "\(type): annotation drawn, no recolor: \(String(describing: p))")
                let w = pixel(files[1], x: 300, y: 400)
                check(w.map { $0.r > 250 && $0.g > 250 && $0.b > 250 } == true, "\(type): page 2 stays white (no recolor)")
            }
        }
        let page2 = path("pages-2.png")
        let page2Before = (try? Data(contentsOf: page2)) ?? Data()
        controller.perform(ActionInvocation(.export, "pages.png 150"))
        check(host.last.contains("pages-1.png and 2 more exists") && (try? Data(contentsOf: page2)) == page2Before,
              "multi-page image export refuses to replace name-N files: \(host.last)")
        controller.perform(ActionInvocation(.export, "pages.png 150 force"))
        check(host.last.hasPrefix("exported 3 files") && abs((pixelSize(page2)?.width ?? 0) - 1275) <= 1 && abs((pixelSize(page2)?.height ?? 0) - 1650) <= 1,
              "multi-page image export with force replaces them: \(host.last)")
        if let typed = try? CommandParser.parse("export \"with space.pdf\"") {
            controller.perform(typed)
            check(PDFDocument(url: path("with space.pdf"))?.pageCount == 3 && !fm.fileExists(atPath: path("with").path),
                  "export to a quoted path with a space: \(host.last)")
        }
        controller.perform(ActionInvocation(.export, "hi.png 144 current"))
        check(pixelSize(path("hi.png")) == CGSize(width: 1224, height: 1584), "export 144 dpi current page: single file, 1224x1584")
        controller.perform(ActionInvocation(.export, "q.jpg quality=20 72 current"))
        controller.perform(ActionInvocation(.export, "q2.jpg quality=95 72 current"))
        check(fileSize(path("q.jpg")) > 0 && fileSize(path("q.jpg")) < fileSize(path("q2.jpg")), "jpeg quality changes the file size")
        controller.perform(ActionInvocation(.export, "x.png 5000"))
        check(host.last.hasPrefix("export:"), "absurd resolution rejected: \(host.last)")
        controller.perform(ActionInvocation(.export, "source.pdf"))
        check(host.last.contains("open file"), "export onto the open file refused")

        // Reduce file size.
        let images = fresh("images.pdf", makeImagePDF)
        let imageSize = fileSize(images)
        if let imageController = PDFDocumentController(url: images) {
            let imageHost = StubHost()
            imageController.host = imageHost
            imageController.perform(ActionInvocation(.export, "small.pdf reduce"))
            let small = fileSize(path("small.pdf"))
            check(imageSize > 1_000_000 && small > 0 && small < imageSize / 2,
                  "reduce file size shrinks images.pdf \(imageSize) -> \(small) bytes (\(imageHost.last))")
            check(PDFDocument(url: path("small.pdf"))?.pageCount == 2, "reduced pdf still has 2 pages")
            imageController.perform(ActionInvocation(.export, "same.pdf"))
            check(fileSize(path("same.pdf")) > imageSize / 2, "plain export does not shrink")
        } else {
            check(false, "image PDF opens")
        }

        // Encryption round trip.
        controller.perform(ActionInvocation(.export, "locked.pdf pw=secret owner=boss noprint"))
        check(host.last.hasPrefix("exported"), "encrypted export written: \(host.last)")
        let locked = PDFDocument(url: path("locked.pdf"))
        check(locked?.isLocked == true && locked?.isEncrypted == true, "encrypted export reopens locked")
        check(locked?.unlock(withPassword: "wrong") == false, "wrong password refused")
        check(locked?.unlock(withPassword: "secret") == true && locked?.pageCount == 3, "open password unlocks")
        check(locked?.allowsPrinting == false && locked?.allowsCopying == true, "permissions: printing off, copying on")
        let owner = PDFDocument(url: path("locked.pdf"))
        check(owner?.unlock(withPassword: "boss") == true && owner?.allowsPrinting == true, "owner password restores permissions")
        controller.perform(ActionInvocation(.export, "bad.pdf pw=secret noprint"))
        check(host.last.contains("owner password"), "permissions need an owner password: \(host.last)")

        // Open locked through the real unlock path; save keeps encryption.
        setenv("BP_PDF_PASSWORD", "wrong", 1)
        check(PDFDocumentController(url: path("locked.pdf")) == nil, "wrong password does not open")
        setenv("BP_PDF_PASSWORD", "secret", 1)
        if let lockedController = PDFDocumentController(url: path("locked.pdf")) {
            let lockedHost = StubHost()
            lockedController.host = lockedHost
            check(lockedController.document?.pageCount == 3 && lockedController.documentPassword == "secret",
                  "encrypted PDF opens after unlock")
            lockedController.isDirty = true
            do { try lockedController.save(to: nil) } catch { check(false, "save encrypted threw \(error)") }
            let again = PDFDocument(url: path("locked.pdf"))
            check(again?.isLocked == true && again?.unlock(withPassword: "secret") == true && again?.pageCount == 3,
                  "save keeps the encryption")
            check(again?.allowsPrinting == false && again?.allowsCopying == true, "save keeps the permissions")
            setenv("BP_PDF_OWNER_PASSWORD", "wrong", 1)
            lockedController.perform(ActionInvocation(.export, "plain.pdf decrypt"))
            check(!fm.fileExists(atPath: path("plain.pdf").path) && lockedHost.last.contains("owner password"),
                  "decrypt with only the user password is refused: \(lockedHost.last)")
            lockedController.perform(ActionInvocation(.export, "rekey.pdf pw=x owner=y"))
            check(!fm.fileExists(atPath: path("rekey.pdf").path), "re-encrypting with only the user password is refused")
            lockedController.perform(ActionInvocation(.pageExport, "1 restricted-pages.pdf"))
            check(!fm.fileExists(atPath: path("restricted-pages.pdf").path) && lockedHost.last.contains("owner"),
                  "page-export of a restricted document needs the owner password: \(lockedHost.last)")
            setenv("BP_PDF_OWNER_PASSWORD", "boss", 1)
            lockedController.perform(ActionInvocation(.export, "plain.pdf decrypt"))
            unsetenv("BP_PDF_OWNER_PASSWORD")
            let plain = PDFDocument(url: path("plain.pdf"))
            check(plain != nil && plain?.isLocked == false && plain?.isEncrypted == false && plain?.pageCount == 3,
                  "export with decrypt writes an unencrypted copy (\(lockedHost.last))")
            lockedController.perform(ActionInvocation(.export, "kept.pdf"))
            check(PDFDocument(url: path("kept.pdf"))?.isLocked == true, "export keeps the encryption by default")
        } else {
            check(false, "encrypted PDF opens with BP_PDF_PASSWORD")
        }
        unsetenv("BP_PDF_PASSWORD")

        // Atomic writes.
        let target = fresh("target.pdf")
        let before = (try? Data(contentsOf: target)) ?? Data()
        struct Boom: Error {}
        do {
            try AtomicWrite.write(to: target) { temp in
                try Data("garbage".utf8).write(to: temp)
                throw Boom()
            }
            check(false, "failing producer throws")
        } catch {
            check((try? Data(contentsOf: target)) == before, "failed write leaves the destination untouched")
            let stray = (try? fm.contentsOfDirectory(atPath: directory.path))?.filter { $0.hasPrefix(".bp-") } ?? []
            check(stray.isEmpty, "failed write leaves no temp files \(stray)")
        }
        let readonlyDirectory = directory.appendingPathComponent("ro", isDirectory: true)
        try? fm.createDirectory(at: readonlyDirectory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readonlyDirectory.path)
        controller.perform(ActionInvocation(.export, "ro/out.pdf"))
        check(host.last.contains("not writable") && !fm.fileExists(atPath: readonlyDirectory.appendingPathComponent("out.pdf").path),
              "export into an unwritable folder fails cleanly: \(host.last)")
        controller.perform(ActionInvocation(.export, "ro/out.png 72"))
        check(host.last.hasPrefix("export:") && (try? fm.contentsOfDirectory(atPath: readonlyDirectory.path))?.isEmpty == true,
              "image export into an unwritable folder fails cleanly")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readonlyDirectory.path)
        controller.perform(ActionInvocation(.export, "nofolder/out.pdf"))
        check(host.last.contains("does not exist"), "export into a missing folder reports it: \(host.last)")

        // Read-only and deleted files.
        let ro = fresh("readonly.pdf")
        let roBefore = (try? Data(contentsOf: ro)) ?? Data()
        if let roController = PDFDocumentController(url: ro) {
            roController.isDirty = true
            try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: ro.path)
            do {
                try roController.save(to: nil)
                check(false, "saving a read-only file throws")
            } catch {
                check(error.localizedDescription.contains("read-only") && (try? Data(contentsOf: ro)) == roBefore,
                      "save to a read-only file is refused, file untouched: \(error.localizedDescription)")
            }
            check(roController.isDirty, "failed save keeps the document dirty")
            try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: ro.path)
        }
        let gone = fresh("gone.pdf")
        if let goneController = PDFDocumentController(url: gone) {
            try? fm.removeItem(at: gone)
            goneController.isDirty = true
            do {
                try goneController.save(to: nil)
                check(PDFDocument(url: gone)?.pageCount == 3 && !goneController.isDirty, "saving a deleted file writes it again")
            } catch { check(false, "save of deleted file threw \(error)") }
        }

        // Saves do not trigger the auto-reload.
        let watched = fresh("watched.pdf")
        if let watchedController = PDFDocumentController(url: watched) {
            let window = DocumentWindowController(document: watchedController)
            window.showWindow(nil)
            check(window.options.autoReload, "auto-reload is on for the watch test")
            await sleep(0.5)
            let original = watchedController.document
            watchedController.isDirty = true
            check(window.saveInPlace(), "in-place save succeeds")
            await sleep(1.0)
            check(watchedController.document === original && !watchedController.isDirty, "in-place save does not reload")
            // An outside change does reload (so the checks above are not vacuous).
            makeTextPDF(at: path("external.pdf"), pages: 5)
            try? fm.removeItem(at: watched)
            try? fm.copyItem(at: path("external.pdf"), to: watched)
            await sleep(1.2)
            check(watchedController.document !== original && watchedController.document?.pageCount == 5,
                  "an outside change still reloads")
            // Save As moves the window over to the new file.
            let watchedBytes = (try? Data(contentsOf: watched)) ?? Data()
            let frame = window.window?.frame
            watchedController.perform(ActionInvocation(.pageDelete))
            check(watchedController.isDirty, "page delete dirties the document")
            let saveAs = try? CommandParser.parse("w \"watched copy.pdf\"")
            window.dispatch(saveAs ?? ActionInvocation(.saveAs, "\"watched copy.pdf\""))
            let copyURL = path("watched copy.pdf").standardizedFileURL
            let app = NSApp.delegate as? AppDelegate
            let moved = app?.window(showing: copyURL)
            check(PDFDocument(url: copyURL)?.pageCount == 4, "save-as wrote the copy with the edit")
            check((try? Data(contentsOf: watched)) == watchedBytes, "save-as leaves the old file as it was")
            check(window.window?.isVisible != true && moved != nil && moved !== window,
                  "save-as replaced the window with one on the copy")
            if let moved {
                check(moved.window?.frame == frame, "the new window keeps the frame")
                check(!moved.content.isDirty && moved.content.fileURL.standardizedFileURL == copyURL,
                      "the new window shows the copy, clean")
                await sleep(0.5)
                moved.content.perform(ActionInvocation(.pageDelete))
                check(moved.saveInPlace(), "save after save-as succeeds")
                check(PDFDocument(url: copyURL)?.pageCount == 3 && (try? Data(contentsOf: watched)) == watchedBytes,
                      "save after save-as writes the new file, not the old one")
                window.dispatch(ActionInvocation(.saveAs, "watched.pdf"))
                check(window.window?.isVisible != true, "old window stays closed")
                moved.dispatch(ActionInvocation(.saveAs, "\"watched copy.pdf\""))
                check(moved.message?.hasPrefix("written") == true, "save-as onto its own file saves in place: \(moved.message ?? "")")
                moved.window?.close()
            }
        } else {
            check(false, "watch test document opens")
        }

        // `set pdfkit-analysis` reaches PDFKit (off by default).
        if let tuned = PDFDocumentController(url: fresh("tuning.pdf")) {
            if let initial = PDFKitTuning.analysisEnabled(of: tuned.pdfView) {
                var options = AppEnvironment.shared.options
                let theme = AppEnvironment.shared.theme
                check(initial == PDFKitTuning.effectiveAnalysis(option: false), "pdfkit-analysis off on open")
                tuned.apply(options: options, theme: theme)
                options.pdfkitAnalysis = true
                tuned.apply(options: options, theme: theme)
                check(PDFKitTuning.analysisEnabled(of: tuned.pdfView) == true, "set pdfkit-analysis true turns it on")
                options.pdfkitAnalysis = false
                tuned.apply(options: options, theme: theme)
                check(PDFKitTuning.analysisEnabled(of: tuned.pdfView) == PDFKitTuning.effectiveAnalysis(option: false),
                      "set pdfkit-analysis false turns it off again")
            } else {
                log("SKIP pdfkit-analysis: documentAnalysisEnabled not available on this PDFKit")
            }
        }

        // Undo does not clear a change that had no undo (OCR, form typing).
        if let undoController = PDFDocumentController(url: fresh("undo.pdf")) {
            let undo = undoController.undoManager
            undo.groupsByEvent = false
            undoController.isDirty = true          // untracked, e.g. OCR
            await sleep(0.1)
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: undoController) { _ in }
            undo.endUndoGrouping()
            undo.undo()
            check(undoController.isDirty, "undo of a later edit keeps an earlier untracked change dirty")
            undoController.isDirty = false          // saved
            undo.beginUndoGrouping()
            undoController.isDirty = true           // reported with its undoable edit
            undo.registerUndo(withTarget: undoController) { _ in }
            undo.endUndoGrouping()
            await sleep(0.1)
            undo.undo()
            check(!undoController.isDirty, "undoing an undoable edit returns to clean")
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: undoController) { _ in }
            undo.endUndoGrouping()
            await sleep(0.1)
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: undoController) { _ in }
            undo.endUndoGrouping()
            undoController.isDirty = true           // reported right after its group (same event)
            await sleep(0.1)
            undo.undo()
            check(undoController.isDirty, "one undo of two edits stays dirty")
            undo.undo()
            check(!undoController.isDirty, "undoing both edits returns to clean")
        }

        // Signatures survive page copies (page-export, drag-out, decrypt).
        if let sigController = PDFDocumentController(url: fresh("signature.pdf")),
           let sigDocument = sigController.document, let page = sigDocument.page(at: 0),
           let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            let signature = SignatureAnnotation(image: context.makeImage()!, bounds: CGRect(x: 300, y: 300, width: 200, height: 100),
                                                name: "test", renderState: sigController.renderState)
            page.addAnnotation(signature)
            let copied = (page.copy() as? PDFPage)?.annotations.compactMap { $0 as? SignatureAnnotation }.first
            check(copied != nil && copied?.aspect == 2, "a copied page keeps the signature image")
            let sigHost = StubHost()
            sigController.host = sigHost
            sigController.perform(ActionInvocation(.pageExport, "1 signature-page.pdf"))
            if let exported = PDFDocument(url: path("signature-page.pdf"))?.page(at: 0),
               let image = PDFExporter.render(exported, dpi: 72) {
                let ns = NSBitmapImageRep(cgImage: image)
                let c = ns.colorAt(x: 400, y: 792 - 350)?.usingColorSpace(.sRGB)
                check(c.map { $0.blueComponent > 0.8 && $0.redComponent < 0.2 } == true,
                      "page-export draws the signature (\(String(describing: c)))")
            } else {
                check(false, "page-export with a signature written: \(sigHost.last)")
            }
            // Page-export safety: never the open file, existing files only with force.
            let sigBytes = (try? Data(contentsOf: path("signature.pdf"))) ?? Data()
            sigController.perform(ActionInvocation(.pageExport, "1 signature.pdf"))
            sigController.perform(ActionInvocation(.pageExport, "1 signature.pdf force"))
            check((try? Data(contentsOf: path("signature.pdf"))) == sigBytes && sigHost.last.contains("open file"),
                  "page-export onto the open file is refused: \(sigHost.last)")
            let keep = fresh("keep.pdf")
            let keepBytes = (try? Data(contentsOf: keep)) ?? Data()
            sigController.perform(ActionInvocation(.pageExport, "1 keep.pdf"))
            check((try? Data(contentsOf: keep)) == keepBytes && sigHost.last.contains("exists"),
                  "page-export refuses to replace an existing file: \(sigHost.last)")
            sigController.perform(ActionInvocation(.pageExport, "1 keep.pdf force"))
            check(PDFDocument(url: keep)?.pageCount == 1, "page-export force replaces it")
            sigController.perform(ActionInvocation(.pageExport, "2 my pages.pdf"))
            check(PDFDocument(url: path("my pages.pdf"))?.pageCount == 1 && !fm.fileExists(atPath: path("my").path),
                  "page-export path with spaces, no range quoting needed: \(sigHost.last)")
            if let typed = try? CommandParser.parse("page-export 1-2 \"quoted pages.pdf\"") {
                sigController.perform(typed)
                check(PDFDocument(url: path("quoted pages.pdf"))?.pageCount == 2, "page-export quoted path")
            }
        } else {
            check(false, "signature test document opens")
        }

        // Print.
        controller.perform(ActionInvocation(.rotateCW)) // 180 now; still pristine for print
        let copy = controller.pristineCopy()
        check(copy?.pageCount == 3 && copy?.page(at: 0)?.rotation == 0, "print copy is pristine (no view rotation)")
        func printed(range: ClosedRange<Int>?, settings: PrintSettings = PrintSettings()) -> PDFDocument? {
            guard let copy else { return nil }
            let out = path("printed-\(range.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "all").pdf")
            try? fm.removeItem(at: out)
            let info = NSPrintInfo()
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
            if let range {
                info.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
                info.dictionary()[NSPrintInfo.AttributeKey.firstPage] = range.lowerBound
                info.dictionary()[NSPrintInfo.AttributeKey.lastPage] = range.upperBound
            }
            let operation = controller.makePrintOperation(copy: copy, info: info, settings: settings)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
            return PDFDocument(url: out)
        }
        let printedAll = printed(range: nil)
        check(printedAll?.pageCount == 3, "print to PDF: 3 pages (\(printedAll?.pageCount ?? -1))")
        if let page = printedAll?.page(at: 0), let image = PDFExporter.render(page, dpi: 72) {
            let size = page.bounds(for: .cropBox).size
            // The red square at (100,100)-(200,200) on a letter page, printed to fit the imageable area.
            let ns = NSBitmapImageRep(cgImage: image)
            var redPixels = 0
            for y in stride(from: 0, to: ns.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: ns.pixelsWide, by: 4) {
                    if let c = ns.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.redComponent > 0.8, c.greenComponent < 0.25 { redPixels += 1 }
                }
            }
            check(redPixels > 150 && size.width > size.height * 0.7 && size.width < size.height,
                  "printed page is portrait and includes the annotation (\(redPixels) red samples, \(size))")
        } else {
            check(false, "printed page renders")
        }
        check(printed(range: 2...3)?.pageCount == 2, "print page range 2-3 prints 2 pages")
        let actual = PrintSettings()
        actual.scaling = .actualSize
        check(printed(range: 1...1, settings: actual)?.pageCount == 1, "print actual size works")

        // Close sheet / quit review need a human; at least check the empty case.
        check(QuitReview.terminateReply(for: []) == .terminateNow, "quit with nothing dirty terminates")

        return ok
    }
}
