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

    static let openableTypes: [UTType] = [.pdf]

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
            alert.informativeText = "The file is missing or is not a PDF."
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
}
