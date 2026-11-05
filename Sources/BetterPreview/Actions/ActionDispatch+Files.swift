import AppKit
import BPCore
import UniformTypeIdentifiers

/// open, open-palette, reload, save, save-as.
extension DocumentWindowController {
    private var appDelegate: AppDelegate? { NSApp.delegate as? AppDelegate }

    /// A user-typed path: `~` expanded, relative to the document's folder.
    func resolvePath(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded).standardizedFileURL }
        return content.fileURL.deletingLastPathComponent().appendingPathComponent(expanded).standardizedFileURL
    }

    func open(_ path: String?) {
        guard let path else {
            appDelegate?.showOpenPanel(in: content.fileURL.deletingLastPathComponent())
            return
        }
        appDelegate?.open(resolvePath(path))
    }

    func reload() {
        guard !content.isDirty else {
            return showMessage("reload: unsaved changes; save or close first", isError: true)
        }
        fileChangedOnDisk = false
        content.reloadFromDisk()
    }

    /// Returns whether the document was written. `force` overwrites a file
    /// that changed on disk without asking (see +Saving).
    @discardableResult
    func saveInPlace(force: Bool = false) -> Bool {
        write(to: nil, force: force)
    }

    /// `save-as [path] [force]`: with a path (relative to the document's
    /// folder; quoted, or bare words with spaces) writes the document there,
    /// refusing to replace an existing file unless "force" follows it, and
    /// the window then shows the new file (like Preview's Save As). Without
    /// a path, shows the save panel.
    func saveAs(_ path: String?) {
        var words = CommandParser.splitArgumentWords(path ?? "")
        var force = false
        if let last = words.last, !last.quoted, ["force", "!"].contains(last.text.lowercased()) {
            force = true
            words.removeLast()
        }
        // `:w force` / `:w!`: an in-place save that may replace a file changed on disk.
        if words.isEmpty, force {
            saveInPlace(force: true)
            return
        }
        guard !words.isEmpty else { return presentSaveAsPanel() }
        guard words.count == 1 || !words.contains(where: \.quoted) else {
            return showMessage("save-as: unexpected '\(words[1].text)' (save-as [path] [force])", isError: true)
        }
        let url = resolvePath(words.map(\.text).joined(separator: " "))
        if url == content.fileURL.standardizedFileURL {
            write(to: nil, force: force)
            return
        }
        if FileManager.default.fileExists(atPath: url.path), !force {
            return showMessage("save-as: \(url.lastPathComponent) exists (add \"force\" to replace it)",
                               isError: true)
        }
        saveAs(to: url)
    }

    private func presentSaveAsPanel() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.directoryURL = content.fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = content.fileURL.lastPathComponent
        if let type = UTType(filenameExtension: content.fileURL.pathExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            if url.standardizedFileURL == content.fileURL.standardizedFileURL {
                write(to: nil)
            } else {
                saveAs(to: url)
            }
        }
    }

    /// Writes to another file and moves the window over to it.
    private func saveAs(to url: URL) {
        // Another window has that file: writing would replace it under it.
        if let other = appDelegate?.window(showing: url), other !== self {
            return showMessage("save-as: \(url.lastPathComponent) is open in another window; close it first",
                               isError: true)
        }
        guard write(to: url) else { return }
        guard let reopened = appDelegate?.reopen(self, as: url) else {
            return showMessage("written \(url.path), but it could not be opened here", isError: true)
        }
        reopened.showMessage("written \(url.path)", isError: false)
    }

    @discardableResult
    private func write(to url: URL?, force: Bool = false) -> Bool {
        commitPendingEdits()
        let inPlace = url == nil || url?.standardizedFileURL == content.fileURL.standardizedFileURL
        if inPlace, !confirmInPlaceWrite(force: force) { return false }
        do {
            try content.save(to: url)
        } catch {
            showMessage("save: \(error.localizedDescription)", isError: true)
            offerSaveAs(after: error, inPlace: url == nil)
            return false
        }
        if inPlace { fileChangedOnDisk = false }
        documentStatusDidChange()
        showMessage("written \((url ?? content.fileURL).path)", isError: false)
        return true
    }

    /// A save that could not be written (read-only file, missing or locked
    /// folder): offer to save a copy elsewhere. Skipped for scripted runs,
    /// which could not answer the sheet.
    private func offerSaveAs(after error: Error, inPlace: Bool) {
        guard inPlace, let window, ProcessInfo.processInfo.environment["BP_SCRIPT"] == nil,
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not save “\(content.fileURL.lastPathComponent)”"
        alert.informativeText = error.localizedDescription + "\n\nYou can save a copy under another name."
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.presentSaveAsPanel() }
        }
    }
}
