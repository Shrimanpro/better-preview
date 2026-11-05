import AppKit
import PDFKit

/// One asynchronous find over a PDFDocument and its results.
///
/// PDFKit searches on a background thread and reports matches (in document
/// order) and completion through the document delegate on the main thread.
///
/// Memory: finding makes PDFKit extract and keep the text layout of every
/// page it searched, ~115 MB for 500 pages of text, for as long as the
/// document lives. So when the shown document is unmodified, the find runs
/// on a private copy opened from the file (`PDFSearchSource.fileURL`), which
/// is released when the find ends; matches are kept as (page, character
/// range) and turned into selections on the shown document only for the
/// pages near the viewport. Documents that may differ from the file
/// (edited, or the file changed since it was loaded) are searched directly.
@MainActor
final class PDFSearch: NSObject, PDFDocumentDelegate {
    struct Match {
        /// 0-based page index.
        let page: Int
        /// The match's characters in the page's text.
        let range: NSRange
        /// Top of the match as a fraction of the page height from the top.
        let top: Double
    }

    weak var controller: PDFDocumentController? {
        didSet { observeController() }
    }
    /// What the shown document was loaded from, recorded when it was set on
    /// the view (open, reload): the file's identity at that moment and
    /// whether any edit, undo or redo happened since. The private copy is
    /// used only while the file is unchanged and nothing was edited.
    private var loaded: (document: PDFDocument, stamp: FileStamp)?
    private var editedSinceLoad = false

    /// Modification date, size and inode of a file.
    struct FileStamp: Equatable {
        var modified: Date?
        var size: Int?
        var inode: Int?

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
            modified = attributes[.modificationDate] as? Date
            size = (attributes[.size] as? NSNumber)?.intValue
            inode = (attributes[.systemFileNumber] as? NSNumber)?.intValue
        }
    }
    /// The document being searched: the shown one or `copy`.
    private weak var document: PDFDocument?
    /// The document matches refer to (the one on screen).
    private weak var shown: PDFDocument?
    /// A private copy opened from the file for one find; nil otherwise.
    private var copy: PDFDocument?
    /// Selections on the shown document, made on demand.
    private var selections: [Int: PDFSelection] = [:]

    private(set) var query = ""
    private var compareOptions: NSString.CompareOptions = []
    private(set) var matches: [Match] = []
    var active: Int?
    private(set) var isRunning = false
    /// Where the running search should jump from (page, top fraction), and
    /// in which direction. Nil once it has jumped, or for quiet re-runs.
    var anchor: (page: Int, top: Double, backward: Bool)?
    /// Re-runs after a reload restore this match index when they finish.
    var restoreActive: Int?
    /// What `highlightedSelections` currently shows, to skip redundant
    /// updates: page window, active match, match count.
    var shownHighlights: (pages: ClosedRange<Int>, active: Int?, count: Int)?

    var activeMatch: Match? { active.map { matches[$0] } }

    /// "3/17", "3/17+" while still searching, "no matches", or "".
    var statusDetail: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return isRunning ? "searching" : "no matches" }
        return "\(active.map { $0 + 1 } ?? 0)/\(matches.count)" + (isRunning ? "+" : "")
    }

    /// Starts a find, cancelling any previous one. Smart case: case-sensitive
    /// only when the query contains an uppercase letter.
    func start(_ query: String, in document: PDFDocument, smartCase: Bool) {
        cancel()
        // Callers set these right after start(); never inherit a previous run's.
        anchor = nil
        restoreActive = nil
        self.query = query
        shown = document
        copy = controller?.searchCopySource.flatMap { url in
            guard isPristine(document, file: url), let copy = PDFDocument(url: url),
                  copy.pageCount == document.pageCount else { return nil }
            // Encrypted files: a locked copy finds nothing; unlock it with
            // the password the shown document was opened with.
            if copy.isLocked, !copy.unlock(withPassword: controller?.documentPassword ?? "") { return nil }
            return copy
        }
        let target = copy ?? document
        self.document = target
        compareOptions = smartCase && query.contains(where: \.isUppercase) ? [] : .caseInsensitive
        matches = []
        selections = [:]
        active = nil
        shownHighlights = nil
        isRunning = true
        target.delegate = self
        target.beginFindString(query, withOptions: compareOptions)
    }

    func cancel() {
        guard isRunning else { return }
        // Cancelling reports the end synchronously; `finish` must ignore it.
        isRunning = false
        if let document, document.isFinding { document.cancelFindString() }
        releaseCopy()
    }

    func clear() {
        cancel()
        query = ""
        matches = []
        selections = [:]
        active = nil
        anchor = nil
        shownHighlights = nil
    }

    /// The match as a selection on the shown document (made on first use).
    func selection(at index: Int) -> PDFSelection? {
        guard matches.indices.contains(index) else { return nil }
        if let cached = selections[index] { return cached }
        let match = matches[index]
        guard let page = shown?.page(at: match.page),
              let selection = page.selection(for: match.range) else { return nil }
        selections[index] = selection
        return selection
    }

    // MARK: Copy safety

    private func observeController() {
        let center = NotificationCenter.default
        center.removeObserver(self)
        loaded = nil
        guard let controller else { return }
        center.addObserver(self, selector: #selector(documentChanged), name: .PDFViewDocumentChanged,
                           object: controller.pdfView)
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerWillUndoChange,
                     .NSUndoManagerWillRedoChange] {
            center.addObserver(self, selector: #selector(documentEdited), name: name, object: controller.changes)
        }
        documentChanged()
    }

    /// A document was loaded from the file (open or reload).
    @objc private func documentChanged() {
        editedSinceLoad = false
        loaded = nil
        guard let controller, let document = controller.document,
              let stamp = FileStamp(controller.fileURL) else { return }
        loaded = (document, stamp)
    }

    @objc private func documentEdited() {
        editedSinceLoad = true
    }

    /// True only if `document` is the one loaded from `file`, nothing was
    /// edited (or undone / redone) since, and the file is unchanged on disk.
    private func isPristine(_ document: PDFDocument, file: URL) -> Bool {
        guard !editedSinceLoad, let loaded, loaded.document === document,
              controller?.isDirty == false else { return false }
        return FileStamp(file) == loaded.stamp
    }

    /// Drops the private copy and, with it, the text PDFKit extracted.
    private func releaseCopy() {
        guard let copy else { return }
        copy.delegate = nil
        self.copy = nil
    }

    // MARK: PDFDocumentDelegate

    nonisolated func didMatchString(_ instance: PDFSelection) {
        onMain { $0.add(instance) }
    }

    nonisolated func documentDidEndDocumentFind(_ notification: Notification) {
        onMain { $0.finish() }
    }

    private nonisolated func onMain(_ body: @escaping @MainActor (PDFSearch) -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { body(self) }
        } else {
            DispatchQueue.main.async { body(self) }
        }
    }

    private func add(_ selection: PDFSelection) {
        // Drop stragglers from a cancelled search for a different string.
        guard isRunning, let document, let text = selection.string,
              text.compare(query, options: compareOptions) == .orderedSame,
              let page = selection.pages.first, selection.numberOfTextRanges(on: page) > 0 else { return }
        let index = document.index(for: page)
        // A copy's pages have the file's boxes: the reference box of the
        // shown page is its untrimmed box, the same thing.
        let box = (copy == nil ? controller?.referenceBox(of: page) : nil) ?? page.bounds(for: .cropBox)
        let rect = selection.bounds(for: page)
        let top = box.height > 0 ? (box.maxY - rect.maxY) / box.height : 0
        let range = selection.range(at: 0, on: page)
        if copy == nil { selections[matches.count] = selection }
        matches.append(Match(page: index, range: range, top: top))
        controller?.searchDidFindMatch(at: matches.count - 1)
    }

    private func finish() {
        // An end notification for a cancelled search arrives while the new
        // one is still running.
        guard isRunning, document?.isFinding != true else { return }
        isRunning = false
        releaseCopy()
        controller?.searchDidFinish()
    }
}
