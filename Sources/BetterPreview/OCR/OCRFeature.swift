import AppKit
import BPCore
@preconcurrency import CoreGraphics
@preconcurrency import PDFKit

/// `ocr [pages|all] [save <path>]`: on-demand text recognition (Vision).
///
/// How the text reaches search, selection and copy: for every recognized page
/// the engine builds a replacement page (original content + invisible text,
/// render mode 3) and this feature swaps it into the in-memory document, so
/// PDFKit's own find, selection and copy see ordinary page text. The document
/// is marked dirty (user decision: closing prompts so OCR work isn't lost);
/// any later Save / Save As / `ocr ... save <path>` writes it into the file.
/// A reload from disk drops it again.
///
/// Pages that already have text are skipped, so the text is never doubled.
@MainActor
final class OCRFeature: PDFFeature {
    unowned let controller: PDFDocumentController

    /// Cancellation flag shared with the worker queue.
    private final class Job: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func cancel() { lock.lock(); flag = true; lock.unlock() }
    }

    private struct Recognized {
        let index: Int
        let page: PDFPage
        let data: Data
        let lines: Int
    }

    private var job: Job?
    /// Keeps App Nap from throttling the worker while a run is going.
    private var activity: NSObjectProtocol?
    private var progress = ""
    /// False until the running job finished its first page.
    private var firstPageDone = true
    private let queue = DispatchQueue(label: "better-preview.ocr", qos: .userInitiated)

    init(controller: PDFDocumentController) {
        self.controller = controller
        OCRSelfTest.runIfRequested()
    }

    var statusFlags: [String] { job == nil ? [] : ["ocr"] }

    func handle(_ invocation: ActionInvocation) -> Bool {
        switch invocation.action.name {
        case .ocr:
            run(argument: invocation.action.argument ?? "")
            return true
        case .abort:
            // Esc cancels a running recognition; other features still see it.
            job?.cancel()
            return false
        default:
            return false
        }
    }

    func documentDidReload() {
        job?.cancel()
    }

    /// The window closes: stop the worker (it would run on for every
    /// remaining page and keep the CGPDFDocument alive).
    func tearDown() {
        job?.cancel()
        job = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Command

    private func say(_ text: String, error: Bool = false) {
        controller.host?.showMessage(text, isError: error)
    }

    private func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return controller.fileURL.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }

    /// True when the page has no text layer (PDFKit extracts nothing).
    private func lacksText(_ page: PDFPage) -> Bool {
        (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func run(argument: String) {
        guard job == nil else { return say("ocr: already running (Esc cancels)", error: true) }
        guard let document = controller.document else { return }

        var tokens = argument.split(separator: " ").map(String.init)
        var savePath: URL?
        if let at = tokens.firstIndex(of: "save") {
            var pathWords = Array(tokens[(at + 1)...])
            var force = false
            if let last = pathWords.last, ["force", "!"].contains(last.lowercased()) {
                force = true
                pathWords.removeLast()
            }
            let path = pathWords.joined(separator: " ")
            guard !path.isEmpty else { return say("ocr: save needs a path", error: true) }
            let url = resolve(path)
            // Same rules as export: never the open file, never an existing
            // file without "force". Checked before any work is done.
            if url == controller.fileURL.standardizedFileURL {
                return say("ocr: that is the open file; run ocr, then save", error: true)
            }
            if !force, FileManager.default.fileExists(atPath: url.path) {
                return say("ocr: \(url.lastPathComponent) exists (add \"force\" to replace it)", error: true)
            }
            savePath = url
            tokens = Array(tokens[..<at])
        }

        // Which pages.
        var wanted: [Int]
        let spec = tokens.joined()
        if spec.isEmpty {
            wanted = (0..<document.pageCount).filter { document.page(at: $0).map(lacksText) ?? false }
            if wanted.isEmpty { wanted = [controller.currentPageIndex] }
        } else if spec == "all" {
            wanted = Array(0..<document.pageCount)
        } else if let set = PagesFeature.parseRanges(spec, pageCount: document.pageCount), !set.isEmpty {
            wanted = Array(set)
        } else {
            return say("ocr: bad page range \"\(spec)\"", error: true)
        }
        let todo = wanted.filter { document.page(at: $0).map(lacksText) ?? false }
        guard !todo.isEmpty else {
            say(wanted.count == 1 ? "ocr: page \(wanted[0] + 1) already has text"
                                  : "ocr: those pages already have text")
            // Still written as asked; the message says so.
            if let savePath { finish(saving: savePath, recognized: 0) }
            return
        }

        nonisolated(unsafe) let jobs: [(index: Int, page: PDFPage, ref: CGPDFPage)] = todo.compactMap { index in
            guard let page = document.page(at: index), let ref = page.pageRef else { return nil }
            return (index, page, ref)
        }
        let languages = OCREngine.languages(from: controller.options.ocrLanguages)
        let job = Job()
        self.job = job
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "Better Preview OCR")
        controller.scheduleStatusUpdate()
        say("ocr: 0/\(jobs.count) pages")

        final class Box: @unchecked Sendable { var items: [Recognized] = [] }
        let box = Box()
        let total = jobs.count
        // PDFPage is main-thread state; only the CGPDFPage crosses over.
        let work = jobs.map { (index: $0.index, ref: $0.ref) }
        // Vision's first run in a new app build compiles its models (see
        // OCREngine); say so instead of looking stuck.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.job === job, self.firstPageDone == false else { return }
            self.say("ocr: preparing text recognition (first run after install or update, up to ~30 s)")
        }
        firstPageDone = false
        queue.async { [weak self] in
            var done = 0
            var results: [(Int, Data, Int)] = []
            for item in work {
                if job.isCancelled { break }
                let result = OCREngine.recognize(page: item.ref, languages: languages, isCancelled: { job.isCancelled })
                done += 1
                if let result { results.append((item.index, result.pdf, result.lineCount)) }
                let snapshot = done
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.firstPageDone = true
                        self?.say("ocr: \(snapshot)/\(total) pages (\(snapshot * 100 / total)%)")
                    }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let byIndex = Dictionary(uniqueKeysWithValues: jobs.map { ($0.index, $0.page) })
                    box.items = results.compactMap { index, data, lines in
                        byIndex[index].map { Recognized(index: index, page: $0, data: data, lines: lines) }
                    }
                    self.complete(box.items, job: job, cancelled: job.isCancelled, requested: total, savePath: savePath)
                }
            }
        }
    }

    // MARK: Applying results

    private func complete(_ items: [Recognized], job: Job, cancelled: Bool, requested: Int, savePath: URL?) {
        self.job = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        let applied = apply(items)
        controller.scheduleStatusUpdate()
        let lines = items.reduce(0) { $0 + $1.lines }
        if cancelled {
            say("ocr: cancelled, \(applied) page\(applied == 1 ? "" : "s") kept")
        } else if applied == 0 {
            say("ocr: no text found", error: true)
        } else if savePath == nil {
            say("ocr: \(applied) page\(applied == 1 ? "" : "s"), \(lines) lines recognized")
        }
        if savePath != nil, !cancelled { finish(saving: savePath, recognized: applied) }
    }

    private func finish(saving url: URL?, recognized: Int) {
        guard let url else { return }
        do {
            try controller.save(to: url)
            say(recognized == 0 ? "ocr: nothing to recognize, written \(url.path)"
                                : "ocr: \(recognized) pages recognized, written \(url.path)")
        } catch {
            say("ocr: save failed: \(error.localizedDescription)", error: true)
        }
    }

    /// Swaps the recognized pages into the document. Returns how many.
    @discardableResult
    private func apply(_ items: [Recognized]) -> Int {
        guard let document = controller.document, !items.isEmpty else { return 0 }
        let position = controller.currentPosition
        controller.scroller.stop()
        var applied = 0
        var replaced: [(old: PDFPage, new: PDFPage)] = []
        for item in items {
            // The document may have changed (pages moved or removed) meanwhile.
            guard document.page(at: item.index) === item.page,
                  let source = BPDocument(data: item.data), let page = source.page(at: 0) else { continue }
            source.removePage(at: 0)
            let old = item.page
            page.rotation = old.rotation
            // The file's crop box, not the trimmed one: trimming is re-run below.
            page.setBounds(controller.trimmer.originalBox(of: old) ?? old.bounds(for: .cropBox), for: .cropBox)
            replaced.append((old, page))
            applied += 1
        }
        guard applied > 0 else { return 0 }
        swapPages(replaced)
        controller.restore(position, animated: false)
        return applied
    }

    /// Puts each `new` page where its `old` page is, moving the annotations
    /// over, and registers the reverse swap as undo ("Recognize Text"), so
    /// undo entries recorded before the swap (markup on those pages, page
    /// moves) still find the page objects they captured once it is undone.
    func swapPages(_ pairs: [(old: PDFPage, new: PDFPage)]) {
        guard let document = controller.document else { return }
        var done: [(old: PDFPage, new: PDFPage)] = []
        for (old, new) in pairs {
            let index = document.index(for: old)
            guard index != NSNotFound, index < document.pageCount, document.page(at: index) === old else { continue }
            for annotation in old.annotations {
                old.removeAnnotation(annotation)
                new.addAnnotation(annotation)
            }
            document.insert(new, at: index + 1)
            document.removePage(at: index)
            done.append((old, new))
        }
        guard !done.isEmpty else { return }
        let undo = controller.undoManager
        // Recognition finishes outside any event: close our own group so the
        // swap is one undo step at once.
        let ownGroup = undo.groupingLevel == 0
        if ownGroup { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.swapPages(done.map { ($0.new, $0.old) }) }
        }
        if !undo.isUndoing && !undo.isRedoing { undo.setActionName("Recognize Text") }
        controller.isDirty = true
        if ownGroup { undo.endUndoGrouping() }
        controller.cachedOutline = nil
        if controller.isTrimmed {
            controller.trimmer.stop()
            controller.updateTrim()
        }
        controller.pdfView.layoutDocumentView()
        controller.rerunSearchQuietly()
        // Marks and jumps follow the replaced pages.
        controller.didReplacePages(done)
        controller.scheduleStatusUpdate()
    }
}
