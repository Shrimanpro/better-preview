import AppKit
import BPCore
import PDFKit

/// SyncTeX in both directions.
///
/// - Inverse search: Cmd-click on a page runs `synctex-editor-command` with
///   the source file and line under the pointer.
/// - Forward search: `forwardSearch(source:line:column:)`, called by the
///   `better-preview://forward?...` URL handler, scrolls the matching box to
///   the middle of the window and flashes it.
///
/// The `.synctex.gz` is parsed lazily on first use, on a background queue,
/// cached per document, and re-parsed when the file changes on disk or the
/// PDF reloads. `set synctex false` turns both directions off.
@MainActor
final class SyncTeXFeature: PDFFeature {
    unowned let controller: PDFDocumentController

    /// Every scanner is created and queried here (the C parser is not
    /// thread-safe, and parsing a big file takes a while).
    nonisolated static let queue = DispatchQueue(label: "better-preview.synctex", qos: .userInitiated)

    private var index: SyncTeXIndex?
    private var pendingLoads: [@MainActor (SyncTeXIndex?) -> Void]?
    /// Bumped on reload so a parse started before it is not cached.
    private var generation = 0
    /// True between a consumed Cmd-mouseDown and its mouseUp.
    private var swallowingClick = false
    private weak var flashView: SyncTeXFlashView?

    // Test hooks (SyncTeXSelfTest).
    /// Used instead of `synctex-editor-command` when set.
    var editorCommandOverride: String?
    /// Called after an editor command finished (status, stderr).
    var onEditorCommandFinished: ((Int32, String) -> Void)?
    private(set) var parseCount = 0
    var currentFlash: SyncTeXFlashView? { flashView }

    init(controller: PDFDocumentController) {
        self.controller = controller
        SyncTeXSelfTest.scheduleIfRequested(self)
    }

    private var pdfView: BPPDFView { controller.pdfView }
    private var isEnabled: Bool { controller.options.synctex }

    func handle(_ invocation: ActionInvocation) -> Bool {
        guard invocation.action.name == .synctexForward else { return false }
        let parts = (invocation.action.argument ?? "").split(separator: " ", maxSplits: 1).map(String.init)
        let position = parts.first?.split(separator: ":").map(String.init) ?? []
        guard let lineText = position.first, let line = Int(lineText), line > 0 else {
            message("usage: synctex-forward <line>[:<column>] [source]", isError: true)
            return true
        }
        let column = position.count > 1 ? Int(position[1]) ?? 0 : 0
        let source = parts.count > 1
            ? parts[1].trimmingCharacters(in: .whitespaces)
            : controller.fileURL.deletingPathExtension().appendingPathExtension("tex").lastPathComponent
        forwardSearch(source: source, line: line, column: column)
        return true
    }

    func documentDidReload() {
        generation += 1
        index = nil
        flashView?.removeFromSuperview()
    }

    // MARK: Mouse (inverse search)

    func handleMouse(_ event: NSEvent) -> Bool {
        if swallowingClick {
            if event.type == .leftMouseUp { swallowingClick = false }
            return event.type == .leftMouseDragged || event.type == .leftMouseUp
        }
        guard event.type == .leftMouseDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              isEnabled,
              // Not a TeX PDF: leave Cmd-click to PDFKit.
              index != nil || SyncTeXIndex.synctexFile(forPDF: controller.fileURL) != nil else { return false }
        let point = pdfView.convert(event.locationInWindow, from: nil)
        guard let document = controller.document, let page = pdfView.page(for: point, nearest: false) else {
            return false
        }
        swallowingClick = true
        inverseSearch(pageIndex: document.index(for: page), pagePoint: pdfView.convert(point, to: page))
        return true
    }

    /// Looks up the source at a point (page space) and opens it in the editor.
    func inverseSearch(pageIndex: Int, pagePoint: CGPoint,
                       completion: (@MainActor (SyncTeXSource?) -> Void)? = nil) {
        guard let page = controller.document?.page(at: pageIndex) else { completion?(nil); return }
        let media = page.bounds(for: .mediaBox)
        let h = Double(pagePoint.x - media.minX)
        let v = Double(media.maxY - pagePoint.y)
        withIndex { [weak self] index in
            guard let self else { return }
            guard let index else {
                completion?(nil)
                return
            }
            // Weak across the queue hop: the window (and the controller this
            // feature points to unowned) may close during a slow parse.
            Self.queue.async { [weak self] in
                let source = index.source(page: pageIndex, h: h, v: v)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.openInEditor(source)
                        completion?(source)
                    }
                }
            }
        }
    }

    private func openInEditor(_ source: SyncTeXSource?) {
        guard let source else {
            message("SyncTeX: no source found for this spot", isError: true)
            return
        }
        let location = "\((source.path as NSString).abbreviatingWithTildeInPath):\(source.line)"
        let template = (editorCommandOverride ?? controller.options.synctexEditorCommand)
            .trimmingCharacters(in: .whitespaces)
        guard !template.isEmpty else {
            message("SyncTeX: \(location). To open it, set synctex-editor-command in the rc, "
                    + "e.g. set synctex-editor-command \"code -g %{input}:%{line}\"", isError: false)
            return
        }
        let command = SyncTeXEditorCommand.expand(template, source: source)
        do {
            try SyncTeXEditorCommand.run(command) { [weak self] status, stderr in
                guard let self else { return }
                if status != 0 {
                    let detail = stderr.isEmpty ? "exit status \(status)" : stderr
                    message("SyncTeX: editor command failed: \(detail)", isError: true)
                }
                onEditorCommandFinished?(status, stderr)
            }
            message("SyncTeX: \(location)", isError: false)
        } catch {
            message("SyncTeX: cannot run editor command: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: Forward search

    /// Scrolls to and flashes what `line` of `source` produced. `source` may
    /// be relative to the PDF's directory. Completion gets the boxes found.
    func forwardSearch(source: String, line: Int, column: Int = 0,
                       completion: (@MainActor ([SyncTeXBox]) -> Void)? = nil) {
        guard isEnabled else {
            message("SyncTeX is off (set synctex true)", isError: true)
            completion?([])
            return
        }
        let hint = controller.currentPageIndex
        withIndex { [weak self] index in
            guard let self else { return }
            guard let index else {
                completion?([])
                return
            }
            Self.queue.async { [weak self] in
                let boxes = index.boxes(sourcePath: source, line: line, column: column, pageHint: hint)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if boxes.isEmpty {
                            let name = (source as NSString).lastPathComponent
                            self.message("SyncTeX: nothing in this PDF comes from \(name):\(line)", isError: true)
                        } else {
                            self.reveal(boxes)
                        }
                        completion?(boxes)
                    }
                }
            }
        }
    }

    /// Records a jump, centres the boxes in the viewport and flashes them.
    func reveal(_ boxes: [SyncTeXBox]) {
        guard let first = boxes.first, let page = controller.document?.page(at: first.page) else { return }
        let media = page.bounds(for: .mediaBox)
        let pageRects = boxes.filter { $0.page == first.page }.map { box in
            CGRect(x: media.minX + box.rect.minX, y: media.maxY - box.rect.maxY,
                   width: max(box.rect.width, 1), height: max(box.rect.height, 1))
        }
        controller.willJump()
        if !controller.isContinuous || controller.scroller.viewport == nil {
            pdfView.go(to: page)
        }
        pdfView.layoutDocumentView()
        guard let documentView = controller.documentView, let viewport = controller.scroller.viewport else {
            pdfView.go(to: pageRects[0], on: page)
            return
        }
        let docRects = pageRects.map { documentView.convert(pdfView.convert($0, from: page), from: pdfView) }
        let target = docRects.dropFirst().reduce(docRects[0]) { $0.union($1) }
        var origin = controller.scroller.destination ?? viewport.origin
        origin.y = target.midY - viewport.height / 2
        if target.minX < origin.x || target.maxX > origin.x + viewport.width {
            origin.x = target.midX - viewport.width / 2
        }
        controller.scroller.jump(to: origin)
        flashView?.removeFromSuperview()
        let color = controller.host?.theme.accent.nsColor ?? .controlAccentColor
        flashView = SyncTeXFlashView.flash(docRects, in: documentView, color: color)
    }

    // MARK: Index cache

    /// Calls `body` with the up-to-date index (parsing it on first use or
    /// after the SyncTeX file changed), or nil after telling the user why.
    func withIndex(_ body: @escaping @MainActor (SyncTeXIndex?) -> Void) {
        let pdfURL = controller.fileURL
        guard let file = SyncTeXIndex.synctexFile(forPDF: pdfURL) else {
            index = nil
            let name = pdfURL.deletingPathExtension().lastPathComponent
            message("SyncTeX: no \(name).synctex.gz next to the PDF (build with -synctex=1)", isError: true)
            body(nil)
            return
        }
        if let index, index.synctexURL == file,
           index.modificationDate == SyncTeXIndex.modificationDate(of: file) {
            body(index)
            return
        }
        if pendingLoads != nil {
            pendingLoads?.append(body)
            return
        }
        pendingLoads = [body]
        let started = generation
        Self.queue.async {
            let parsed = SyncTeXIndex(pdfURL: pdfURL)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { [weak self] in
                    guard let self else { return }
                    parseCount += 1
                    if started == generation { index = parsed }
                    if parsed == nil { message("SyncTeX: cannot read \(file.lastPathComponent)", isError: true) }
                    let waiting = pendingLoads ?? []
                    pendingLoads = nil
                    for callback in waiting { callback(parsed) }
                }
            }
        }
    }

    private func message(_ text: String, isError: Bool) {
        controller.host?.showMessage(text, isError: isError)
    }
}
