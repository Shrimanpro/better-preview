import AppKit
import BPCore
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: [DocumentWindowController] = []
    private var openedAnything = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        ConfigController.shared.start()
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTiming.mark("finished-launching")
        // Files given on the command line: `BetterPreview a.pdf b.png`.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args {
            open(URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        NSApp.activate()
        DebugScript.runIfRequested { [weak self] in self?.windows.first }
        // Launched with nothing to show: offer the Open panel, like Preview.
        DispatchQueue.main.async { [self] in
            if !openedAnything { showOpenPanel() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { open(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Text boxes and form fields being edited count as changes (H2, M6).
        for window in windows { window.commitPendingEdits() }
        return QuitReview.terminateReply(for: windows.filter(\.content.isDirty))
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Opening

    static let openableTypes: [UTType] = [.pdf, .image]

    @discardableResult
    func open(_ url: URL) -> DocumentWindowController? {
        openedAnything = true
        let url = url.standardizedFileURL
        if let existing = windows.first(where: { $0.content.fileURL == url }) {
            existing.showWindow(nil)
            return existing
        }
        guard let document = DocumentFactory.make(for: url) else {
            // The user cancelled the password prompt: nothing to report.
            if PasswordPrompt.takeCancellation() { return nil }
            let alert = NSAlert()
            alert.messageText = "Cannot open “\(url.lastPathComponent)”"
            alert.informativeText = "The file is missing or is not a PDF or image."
            alert.runModal()
            return nil
        }
        let controller = DocumentWindowController(document: document)
        // Offset from the newest window instead of stacking exactly on it.
        if let last = windows.last?.window, let window = controller.window {
            window.setFrameTopLeftPoint(last.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        }
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        windows.append(controller)
        controller.showWindow(nil)
        LaunchTiming.mark("window-shown")
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return controller
    }

    /// Save As: `old` was just written to `url`. Like Preview, the window
    /// now shows and edits that file: it is reopened in the same frame at the
    /// same position and zoom, and the old window closes without asking (its
    /// changes are in the new file; the old file keeps its last saved state).
    /// Undo history, marks and the jump list start fresh. Returns the new
    /// window, or nil (the old one stays) if the copy cannot be opened.
    @discardableResult
    func reopen(_ old: DocumentWindowController, as url: URL) -> DocumentWindowController? {
        let url = url.standardizedFileURL
        if let password = (old.content as? PDFDocumentController)?.documentPassword {
            PasswordPrompt.knownPassword = (url, password)
        }
        defer { PasswordPrompt.knownPassword = nil }
        guard let document = DocumentFactory.make(for: url) else { return nil }
        let controller = DocumentWindowController(document: document)
        if let oldWindow = old.window, let window = controller.window {
            window.setFrame(oldWindow.frame, display: false)
        }
        controller.onClose = { [weak self, weak controller] in
            self?.windows.removeAll { $0 === controller }
        }
        // Same place in the list (scripts drive `windows.first`).
        let index = windows.firstIndex { $0 === old } ?? windows.count
        windows.insert(controller, at: index)
        let position = old.content.currentPosition
        let zoom = old.content.status.zoom
        if let pdf = controller.content as? PDFDocumentController {
            pdf.deferUntilLaidOut { [weak pdf] in
                guard let pdf else { return }
                if abs(pdf.status.zoom - zoom) > 0.0005 {
                    _ = pdf.perform(ActionInvocation(.zoomSet, String(format: "%.3f", zoom * 100)))
                }
                pdf.go(to: position, animated: false)
            }
        } else {
            controller.content.go(to: position, animated: false)
        }
        controller.showWindow(nil)
        old.window?.close()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return controller
    }

    /// The window showing `url`, if any.
    func window(showing url: URL) -> DocumentWindowController? {
        windows.first { $0.content.fileURL.standardizedFileURL == url.standardizedFileURL }
    }

    @objc func showOpenPanel() {
        showOpenPanel(in: nil)
    }

    func showOpenPanel(in directory: URL?) {
        openedAnything = true
        let panel = NSOpenPanel()
        panel.directoryURL = directory
        panel.allowedContentTypes = Self.openableTypes
        panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls { self?.open(url) }
        }
    }

    // MARK: URL scheme (better-preview://forward?line=&src=&pdf=)

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: string) else { return }
        URLSchemeHandler.handle(url, app: self)
    }
}

/// Entry point for `better-preview://` URLs.
///
/// `better-preview://forward?pdf=<path>&src=<path>&line=<n>[&column=<n>]`
/// opens the PDF (or brings its window forward) and, when `line` is given,
/// runs a SyncTeX forward search. `pdf` and `src` may be paths or `file://`
/// URLs; a relative `src` is taken relative to the PDF's directory.
@MainActor
enum URLSchemeHandler {
    struct ForwardRequest: Equatable {
        var pdf: URL
        var source: String?
        var line: Int?
        var column: Int
    }

    static func parse(_ url: URL) -> ForwardRequest? {
        guard url.scheme?.lowercased() == "better-preview",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = (components.host ?? components.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard action.isEmpty || action.lowercased() == "forward" else { return nil }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value, !value.isEmpty { values[item.name.lowercased()] = value }
        }
        guard let pdf = values["pdf"].map(fileURL(from:)) else { return nil }
        // Lines are 1-based; anything else (0, negative, not a number) just
        // opens the PDF. Huge values are clamped by the SyncTeX query.
        let line = values["line"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 1 ? $0 : nil }
        let column = max(0, values["column"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0)
        let source = values["src"].map { value -> String in
            value.lowercased().hasPrefix("file:") ? (URL(string: value)?.path ?? value) : value
        }
        return ForwardRequest(pdf: pdf, source: source, line: line, column: column)
    }

    private static func fileURL(from value: String) -> URL {
        if value.lowercased().hasPrefix("file:"), let url = URL(string: value), url.isFileURL { return url }
        return URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
    }

    /// `completion` gets the boxes the forward search found (empty when
    /// there was no search or no match).
    static func handle(_ url: URL, app: AppDelegate,
                       completion: (@MainActor ([SyncTeXBox]) -> Void)? = nil) {
        guard let request = parse(url) else {
            completion?([])
            return
        }
        NSApp.activate()
        guard let window = app.open(request.pdf) else {
            completion?([])
            return
        }
        window.window?.makeKeyAndOrderFront(nil)
        guard let line = request.line, let pdf = window.content as? PDFDocumentController,
              let syncTeX = pdf.features.lazy.compactMap({ $0 as? SyncTeXFeature }).first else {
            completion?([])
            return
        }
        // A window that was just created lays itself out on its first
        // resize; searching before that would be undone by it.
        whenLaidOut(pdf, attempts: 40) {
            syncTeX.forwardSearch(source: request.source ?? defaultSource(for: request.pdf), line: line,
                                  column: request.column, completion: completion)
        }
    }

    /// No `src`: the `.tex` file named like the PDF.
    private static func defaultSource(for pdf: URL) -> String {
        pdf.deletingPathExtension().appendingPathExtension("tex").path
    }

    private static func whenLaidOut(_ pdf: PDFDocumentController, attempts: Int,
                                    _ body: @escaping @MainActor () -> Void) {
        let view = pdf.pdfView
        if view.window?.isVisible == true, view.bounds.width > 1, pdf.documentView != nil || attempts <= 0 {
            DispatchQueue.main.async { MainActor.assumeIsolated { body() } }
            return
        }
        guard attempts > 0 else { return body() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) {
            MainActor.assumeIsolated { whenLaidOut(pdf, attempts: attempts - 1, body) }
        }
    }
}
