import AppKit
import BPCore
import PDFKit

/// `BP_OCR_SELFTEST=1 BetterPreview <any pdf>`: builds an image-only (scanned)
/// PDF in build/tmp, runs `ocr` through the real action path, then checks that
/// search, selection and copy text work, that the pages still render through
/// the recolor page class, that `ocr all save <path>` writes a PDF that
/// reopens with text, and that a cancelled run is harmless. Prints PASS/FAIL
/// lines and `OCR SELFTEST PASS|FAIL` to stderr, then exits (1 on failure).
@MainActor
enum OCRSelfTest {
    private static var hasRun = false

    static func runIfRequested() {
        guard !hasRun, ProcessInfo.processInfo.environment["BP_OCR_SELFTEST"] == "1" else { return }
        hasRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Task { @MainActor in
                let ok = await run()
                log(ok ? "OCR SELFTEST PASS" : "OCR SELFTEST FAIL")
                exit(ok ? 0 : 1)
            }
        }
    }

    private static let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/tmp", isDirectory: true)
    private static var ok = true

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func check(_ condition: Bool, _ message: String) {
        log((condition ? "PASS " : "FAIL ") + message)
        if !condition { ok = false }
    }

    private final class StubHost: DocumentHost {
        var options: Options { AppEnvironment.shared.options }
        var theme: Theme { AppEnvironment.shared.theme }
        var mode: Mode = .normal
        var messages: [String] = []
        func setMode(_ mode: Mode) { self.mode = mode }
        func dispatch(_ invocation: ActionInvocation) {}
        func documentStatusDidChange() {}
        func showMessage(_ text: String, isError: Bool) { messages.append(text) }
        func recordJump(from position: DocumentPosition) {}
    }

    // MARK: Test document

    static let pageTexts = [
        ["Quarterly report", "The quick brown fox jumps over the lazy dog", "Revenue grew steadily this year"],
        ["Appendix with the unique marker ZEBRAFISH", "Another sentence about network latency", "Final words on page two"],
        ["Third page here", "Meeting notes for Thursday afternoon", "Please remember the umbrella"],
    ]

    /// A PDF whose pages hold only a bitmap of the text: no text layer.
    static func makeScannedPDF(at url: URL) -> Bool {
        let size = CGSize(width: 612, height: 792)
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return false }
        let scale: CGFloat = 2.5
        for lines in pageTexts {
            let width = Int(size.width * scale), height = Int(size.height * scale)
            guard let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceGray(),
                                         bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            bitmap.setFillColor(gray: 1, alpha: 1)
            bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: bitmap, flipped: false)
            for (i, line) in lines.enumerated() {
                let text = NSAttributedString(string: line, attributes: [
                    .font: NSFont.systemFont(ofSize: 17 * scale), .foregroundColor: NSColor.black])
                text.draw(at: CGPoint(x: 60 * scale, y: (700 - CGFloat(i) * 70) * scale))
            }
            NSGraphicsContext.restoreGraphicsState()
            guard let image = bitmap.makeImage() else { return false }
            context.beginPDFPage(nil)
            context.draw(image, in: box)
            context.endPDFPage()
        }
        context.closePDF()
        return true
    }

    // MARK: Checks

    private static func waitUntil(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    private static func run() async -> Bool {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scanned = directory.appendingPathComponent("ocr-scanned.pdf")
        check(makeScannedPDF(at: scanned), "scanned test PDF written")
        guard let controller = PDFDocumentController(url: scanned), let document = controller.document else {
            check(false, "scanned PDF opens")
            return false
        }
        let host = StubHost()
        controller.host = host
        func hasText(_ d: PDFDocument) -> [Bool] {
            (0..<d.pageCount).map { !($0 < d.pageCount ? (d.page(at: $0)?.string ?? "") : "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        check(hasText(document) == [false, false, false], "scanned pages start without text")

        // Default: every page without a text layer.
        controller.perform(ActionInvocation(.ocr))
        let finished = await waitUntil(120) { host.messages.last?.contains("lines recognized") == true || host.messages.last?.contains("no text") == true }
        check(finished, "ocr finishes (\(host.messages.last ?? "no message"))")
        check(controller.document === document, "same document object")
        check(hasText(document) == [true, true, true], "all three pages now have text")
        let page2 = document.page(at: 1)
        check(page2 is RecolorPage && page2?.document === document, "recognized page is a RecolorPage in the document")
        check(controller.isDirty, "ocr marks the document dirty")
        check((page2?.string ?? "").lowercased().contains("zebrafish"), "page text contains ZEBRAFISH: \(page2?.string?.prefix(80) ?? "")")
        check(document.pageCount == 3 && document.page(at: 0)?.bounds(for: .cropBox) == CGRect(x: 0, y: 0, width: 612, height: 792),
              "page count and size unchanged")

        // Search.
        controller.perform(ActionInvocation(.searchRun, "zebrafish"))
        _ = await waitUntil(20) { !controller.search.isRunning }
        check(controller.search.matches.count == 1 && controller.search.matches.first?.page == 1,
              "search finds ZEBRAFISH on page 2 (\(controller.search.matches.count) matches)")
        controller.perform(ActionInvocation(.searchRun, "the"))
        _ = await waitUntil(20) { !controller.search.isRunning }
        check(controller.search.matches.count >= 3, "search finds \"the\" on several pages (\(controller.search.matches.count))")
        controller.perform(ActionInvocation(.searchNext))
        controller.perform(ActionInvocation(.searchClear))

        // Selection and copy.
        if let page = document.page(at: 0) {
            let selection = page.selection(for: page.bounds(for: .cropBox))
            let text = selection?.string ?? ""
            check(text.lowercased().contains("quick brown fox"), "selecting the page returns its text: \(text.prefix(60))")
            controller.pdfView.setCurrentSelection(selection, animate: false)
            NSPasteboard.general.clearContents()
            controller.perform(ActionInvocation(.copy))
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            check(pasted.lowercased().contains("lazy dog"), "copy puts the recognized text on the pasteboard")
            // A word-sized rect near the first line selects only part of the text.
            let sub = page.selection(for: CGRect(x: 60, y: 695, width: 300, height: 30))
            check(!(sub?.string ?? "").isEmpty && (sub?.string ?? "").count < text.count, "sub-rect selection is a partial line: \(sub?.string ?? "")")
        }

        // Already has text: no-op, no duplicates.
        host.messages.removeAll()
        controller.perform(ActionInvocation(.ocr, "all"))
        check(host.messages.last?.contains("already have text") == true, "ocr on pages with text is a no-op")

        // Save as searchable PDF on a fresh copy, with a page range and cancel path.
        guard let second = PDFDocumentController(url: scanned) else { return false }
        second.host = host
        let saved = directory.appendingPathComponent("ocr-searchable.pdf")
        try? FileManager.default.removeItem(at: saved)
        host.messages.removeAll()
        second.perform(ActionInvocation(.ocr, "all save \(saved.path)"))
        let wrote = await waitUntil(120) { host.messages.last?.contains("written") == true }
        check(wrote, "ocr all save writes a file (\(host.messages.last ?? ""))")
        if let reopened = PDFDocument(url: saved) {
            check(reopened.pageCount == 3, "saved PDF has 3 pages")
            check(hasText(reopened) == [true, true, true], "saved PDF pages have text")
            check(!reopened.findString("ZEBRAFISH", withOptions: .caseInsensitive).isEmpty, "saved PDF is searchable")
            check(reopened.page(at: 0)?.thumbnail(of: CGSize(width: 100, height: 130), for: .cropBox).size.width ?? 0 > 0,
                  "saved PDF renders")
        } else {
            check(false, "saved PDF reopens")
        }

        // Cancel right away: must end cleanly with the document intact.
        guard let third = PDFDocumentController(url: scanned) else { return false }
        third.host = host
        host.messages.removeAll()
        third.perform(ActionInvocation(.ocr, "all"))
        third.perform(ActionInvocation(.abort))
        let ended = await waitUntil(120) {
            host.messages.last?.contains("cancelled") == true || host.messages.last?.contains("lines recognized") == true
        }
        check(ended && third.document?.pageCount == 3, "abort ends the run cleanly (\(host.messages.last ?? ""))")
        return ok
    }
}
