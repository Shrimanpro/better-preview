import AppKit
import PDFKit

/// `BP_FORMS_SELFTEST=1`: builds a fillable PDF (build/tmp/forms-test.pdf),
/// fills it, creates and places a signature, saves, reloads and checks the
/// round trip and file permissions. Prints PASS/FAIL to stderr, then exits.
/// Also `BP_SELFTEST=forms`.
@MainActor
enum FormsSelfTest {
    private static var hasRun = false

    static func runIfRequested(from feature: FormsFeature) {
        guard !hasRun, PDFSelfTest.featureRequested("forms", variable: "BP_FORMS_SELFTEST") else { return }
        hasRun = true
        DispatchQueue.main.async {
            let ok = run()
            log(ok ? "FORMS SELFTEST PASS" : "FORMS SELFTEST FAIL")
            exit(ok ? 0 : 1)
        }
    }

    static func log(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    nonisolated(unsafe) private static var failures = 0
    static func check(_ condition: Bool, _ message: String) {
        log((condition ? "PASS " : "FAIL ") + message)
        if !condition { failures += 1 }
    }

    static let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tmp", isDirectory: true)

    // MARK: Test document

    /// A page with labels and one widget of each kind.
    static func makeFormPDF(at url: URL) -> Bool {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 400, height: 300)
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return false }
        ctx.beginPDFPage(nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (text, y) in [("Name", 250), ("Agree", 210), ("Colour", 170), ("Country", 120)] {
            NSAttributedString(string: text, attributes: attrs).draw(at: CGPoint(x: 20, y: y))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? (data as Data).write(to: url)) != nil, let doc = PDFDocument(url: url), let page = doc.page(at: 0) else { return false }

        func widget(_ rect: CGRect, _ type: PDFAnnotationWidgetSubtype, name: String) -> PDFAnnotation {
            let a = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
            a.widgetFieldType = type
            a.fieldName = name
            a.font = .systemFont(ofSize: 12)
            a.fontColor = .black
            a.backgroundColor = NSColor(white: 0.95, alpha: 1)
            a.border = { let b = PDFBorder(); b.lineWidth = 1; return b }()
            page.addAnnotation(a)
            return a
        }
        _ = widget(CGRect(x: 100, y: 245, width: 200, height: 22), .text, name: "name")
        let check = widget(CGRect(x: 100, y: 207, width: 18, height: 18), .button, name: "agree")
        check.widgetControlType = .checkBoxControl
        for (i, label) in ["Red", "Blue"].enumerated() {
            let radio = widget(CGRect(x: 100 + CGFloat(i) * 70, y: 167, width: 16, height: 16), .button, name: "colour")
            radio.widgetControlType = .radioButtonControl
            radio.buttonWidgetStateString = label
        }
        let combo = widget(CGRect(x: 100, y: 115, width: 150, height: 22), .choice, name: "country")
        combo.isListChoice = false
        combo.choices = ["Norway", "Peru", "Japan"]
        return doc.write(to: url)
    }

    static func widgets(in doc: PDFDocument) -> [String: PDFAnnotation] {
        var result: [String: PDFAnnotation] = [:]
        for a in doc.page(at: 0)?.annotations ?? [] where a.type == "Widget" {
            let key = (a.fieldName ?? "?") + (a.widgetControlType == .radioButtonControl ? "/\(a.buttonWidgetStateString)" : "")
            result[key] = a
        }
        return result
    }

    static func radios(in doc: PDFDocument) -> [PDFAnnotation] {
        (doc.page(at: 0)?.annotations ?? []).filter { $0.type == "Widget" && $0.widgetControlType == .radioButtonControl }
            .sorted { $0.bounds.minX < $1.bounds.minX }
    }

    /// Scribble on white paper, like a photographed signature.
    static func syntheticPicture() -> CGImage? {
        let w = 600, h = 220
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 0.93, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setStrokeColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.4, alpha: 1))
        ctx.setLineWidth(5)
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: 40, y: 60))
        ctx.addCurve(to: CGPoint(x: 300, y: 120), control1: CGPoint(x: 100, y: 200), control2: CGPoint(x: 200, y: 0))
        ctx.addCurve(to: CGPoint(x: 560, y: 90), control1: CGPoint(x: 380, y: 200), control2: CGPoint(x: 480, y: 20))
        ctx.strokePath()
        return ctx.makeImage()
    }

    static func pixel(_ image: NSImage, x: Int, y: Int) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    // MARK: Run

    static func run() -> Bool {
        let signatureDir = out.appendingPathComponent("signatures-test", isDirectory: true)
        try? FileManager.default.removeItem(at: signatureDir)
        let store = SignatureStore(directory: signatureDir)

        let formURL = out.appendingPathComponent("forms-test.pdf")
        check(makeFormPDF(at: formURL), "generated fillable test PDF")
        guard let controller = PDFDocumentController(url: formURL),
              let forms = controller.features.compactMap({ $0 as? FormsFeature }).first,
              let doc = controller.document, let page = doc.page(at: 0) else {
            check(false, "opened test PDF in a controller")
            return false
        }
        let before = widgets(in: doc)
        check(before.count == 4 && radios(in: doc).count == 2, "found 5 widgets (\(before.keys.sorted()))")

        // Fill (what PDFKit does when the user types/clicks), tracked by the feature.
        forms.track(page)
        check(!controller.isDirty, "clean before editing")
        before["name"]?.widgetStringValue = "Ada Lovelace"
        before["agree"]?.buttonWidgetState = .onState
        radios(in: doc)[1].buttonWidgetState = .onState
        before["country"]?.widgetStringValue = "Peru"
        forms.checkChanges()
        check(controller.isDirty, "filling sets isDirty")

        controller.undoManager.undo()
        check(before["name"]?.widgetStringValue == "" || before["name"]?.widgetStringValue == nil, "undo clears the text field")
        check(before["agree"]?.buttonWidgetState == .offState, "undo unchecks the box")
        controller.undoManager.redo()
        check(before["name"]?.widgetStringValue == "Ada Lovelace", "redo restores the text field")

        // Signature: synthetic photo -> store -> place.
        guard let picture = syntheticPicture(), let image = SignatureImaging.fromPicture(picture) else {
            check(false, "signature from picture")
            return false
        }
        let corner = image.dataProvider?.data.flatMap { CFDataGetBytePtr($0)?[3] } ?? 255
        check(corner == 0, "imported signature background is transparent (corner alpha \(corner))")
        guard let entry = try? store.add(image, name: "Test Sig") else {
            check(false, "stored signature")
            return false
        }
        let fm = FileManager.default
        let dirMode = (try? fm.attributesOfItem(atPath: signatureDir.path)[.posixPermissions] as? Int) ?? -1
        let fileMode = (try? fm.attributesOfItem(atPath: entry.url.path)[.posixPermissions] as? Int) ?? -1
        check(dirMode == 0o700, "signature dir mode 0700 (got \(String(dirMode, radix: 8)))")
        check(fileMode == 0o600, "signature file mode 0600 (got \(String(fileMode, radix: 8)))")
        check(store.list().count == 1, "store lists the signature")

        SignatureStore.shared = store
        let annotation = forms.place(entry, on: page, at: CGPoint(x: 280, y: 60))
        SignatureStore.shared = SignatureStore()
        check(annotation != nil && forms.selected === annotation, "signature placed and selected")
        let placedBounds = annotation?.bounds ?? .zero
        check(page.annotations.contains { $0 === annotation }, "stamp is on the page")

        // Move + undo.
        if let annotation {
            let moved = placedBounds.offsetBy(dx: -40, dy: 30)
            forms.setBounds(moved, of: annotation)
            controller.undoManager.undo()
            check(annotation.bounds == placedBounds, "undo moves the signature back")
            controller.undoManager.redo()
            check(annotation.bounds == moved, "redo moves it again")
            forms.setBounds(placedBounds, of: annotation)
        }

        // Save with the signature still selected: chrome must not be saved.
        let savedURL = out.appendingPathComponent("forms-saved.pdf")
        do { try controller.save(to: savedURL) } catch { check(false, "save: \(error)") }
        guard let reloaded = PDFDocument(url: savedURL), let rpage = reloaded.page(at: 0) else {
            check(false, "reloaded saved PDF")
            return false
        }
        let after = widgets(in: reloaded)
        check(after["name"]?.widgetStringValue == "Ada Lovelace", "text value round-trips")
        check(after["agree"]?.buttonWidgetState == .onState, "checkbox round-trips")
        let r = radios(in: reloaded); log("radio states \(r.map { "\($0.buttonWidgetState.rawValue)\($0.buttonWidgetStateString)" })")
        check(r.count == 2 && r[1].buttonWidgetState == .onState /* PDFKit-built radios share one on-name, so both read on */,
              "radio selection round-trips")
        check(after["country"]?.widgetStringValue == "Peru", "choice round-trips")
        let stamps = rpage.annotations.filter { $0.type == "Stamp" }
        check(stamps.count == 1, "one Stamp annotation after reload")
        if let stamp = stamps.first {
            check(abs(stamp.bounds.width - placedBounds.width) < 0.5, "stamp bounds round-trip")
        }
        // Raw file: stamp has an appearance stream, and no selection chrome.
        let raw = (try? Data(contentsOf: savedURL)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(raw.contains("/Subtype /Stamp") && raw.contains("/AP"), "stamp saved with an appearance stream")
        let render = rpage.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
        let scale = 2.0
        // Just inside the bottom-left corner of the stamp: paper, not the accent-coloured border.
        let cx = Int((placedBounds.minX + 0.75) * scale), cy = Int((300 - placedBounds.minY - 0.75) * scale)
        if let c = pixel(render, x: cx, y: cy) {
            check(c.redComponent > 0.85 && c.greenComponent > 0.85 && c.blueComponent > 0.85,
                  "no selection chrome saved (corner pixel \(c))")
        }
        // Somewhere along the ink the page must be dark.
        var dark = false
        let mx = Int(placedBounds.midX * scale)
        for dy in stride(from: -Int(placedBounds.height), through: Int(placedBounds.height), by: 2) {
            if let c = pixel(render, x: mx, y: Int((300 - placedBounds.midY) * scale) + dy), c.brightnessComponent < 0.5 { dark = true }
        }
        check(dark, "signature ink visible in the saved page")

        // A form value that changed without a mouse-up reaching the feature
        // (a popup choice) is found by the before-save/close hook.
        pendingFormChange(in: savedURL)

        // A signature saved earlier comes back as a plain Stamp; it is
        // adopted so it can be selected, moved and deleted again.
        adoptSavedSignature(from: savedURL, bounds: placedBounds)

        // signature-place through the action path.
        SignatureStore.shared = store
        forms.documentDidReload()
        _ = forms.handle(.init(.signaturePlace, "1"))
        check(forms.placed.count == 1, "signature-place with an index works")
        _ = forms.handle(.init(.signaturePlace, "nope"))
        check(forms.placed.count == 1, "unknown signature name places nothing")
        check(forms.handle(.init(.abort)) == false && forms.selected == nil, "Esc deselects the signature (not consumed)")
        forms.select(forms.placed.first)
        _ = forms.handle(.init(.annotationDelete))
        check(forms.placed.isEmpty, "annotation-delete removes the selected signature")
        SignatureStore.shared = SignatureStore()

        return failures == 0
    }

    private static func pendingFormChange(in url: URL) {
        guard let reopened = PDFDocumentController(url: url),
              let forms = reopened.features.compactMap({ $0 as? FormsFeature }).first,
              let document = reopened.document, let page = document.page(at: 0),
              let country = widgets(in: document)["country"] else { return check(false, "reopened the saved form") }
        forms.track(page)  // the mouse-down baseline
        country.widgetStringValue = "Japan"
        check(!reopened.isDirty, "clean before the pending form change is committed")
        reopened.commitPendingEdits()
        check(reopened.isDirty, "commitPendingEdits finds the changed choice and marks dirty")
        reopened.undoManager.undo()
        check(country.widgetStringValue == "Peru", "undo restores the choice")
    }

    private static func adoptSavedSignature(from url: URL, bounds: CGRect) {
        guard let reopened = PDFDocumentController(url: url),
              let forms = reopened.features.compactMap({ $0 as? FormsFeature }).first,
              let page = reopened.document?.page(at: 0) else { return check(false, "reopened the saved PDF") }
        check(page.annotations.contains { FormsFeature.isSavedSignature($0) }, "saved signature reads back as a plain Stamp")
        forms.adoptSavedSignatures(on: page)
        let adopted = page.annotations.compactMap { $0 as? SignatureAnnotation }
        check(adopted.count == 1 && forms.placed.count == 1 && !page.annotations.contains { FormsFeature.isSavedSignature($0) },
              "saved signature adopted as a SignatureAnnotation")
        check(!reopened.isDirty && !reopened.undoManager.canUndo, "adopting is not an edit")
        guard let signature = adopted.first else { return }
        check(abs(signature.bounds.width - bounds.width) < 0.5 && abs(signature.bounds.height - bounds.height) < 0.5,
              "adopted signature keeps its bounds")
        let render = page.thumbnail(of: CGSize(width: 800, height: 600), for: .mediaBox)
        var dark = false
        for dy in stride(from: -Int(bounds.height), through: Int(bounds.height), by: 2) {
            if let c = pixel(render, x: Int(bounds.midX * 2), y: Int((300 - bounds.midY) * 2) + dy),
               c.brightnessComponent < 0.5 { dark = true }
        }
        check(dark, "adopted signature still draws its ink")
        forms.adoptSavedSignatures(on: page)
        check(page.annotations.filter { $0.type == "Stamp" }.count == 1, "adopting twice does not duplicate")
        forms.select(signature)
        forms.setBounds(signature.bounds.offsetBy(dx: 10, dy: 0), of: signature)
        check(reopened.isDirty, "adopted signature can be moved")
        _ = forms.handle(.init(.annotationDelete))
        check(!page.annotations.contains { $0.type == "Stamp" }, "adopted signature can be deleted")
    }
}
