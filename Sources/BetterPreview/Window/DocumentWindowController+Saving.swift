import AppKit
import BPCore

/// What has to happen before the document is written or its dirty state is
/// read for closing and quitting.
extension DocumentWindowController {
    /// Ends text editing inside the document (a markup text box or note, a
    /// form field), so its value is in the document and recorded, and lets
    /// the features record edits still in progress. Text in the input bar or
    /// other windows is left alone.
    func commitPendingEdits() {
        if let window, let text = window.firstResponder as? NSText, text.isDescendant(of: content.view) {
            window.makeFirstResponder(content.preferredFirstResponder)
        }
        if mode == .insert { setMode(baseMode) }
        (content as? PDFDocumentController)?.commitPendingEdits()
    }

    /// Before an in-place save: when the file changed on disk while the
    /// document had unsaved changes (it was not reloaded), saving would
    /// silently replace the newer file. Asks Overwrite / Save As / Cancel;
    /// scripted runs (BP_SCRIPT) cannot answer, so they refuse unless forced
    /// (`:w force`, `:save force`). Returns whether to write.
    func confirmInPlaceWrite(force: Bool) -> Bool {
        guard fileChangedOnDisk, !force else { return true }
        let name = content.fileURL.lastPathComponent
        if ProcessInfo.processInfo.environment["BP_SCRIPT"] != nil {
            showMessage("save: \(name) changed on disk since it was opened; "
                        + "\":w force\" overwrites it, or use save-as", isError: true)
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "“\(name)” was changed by another application."
        alert.informativeText = "It changed on disk while you had unsaved changes. Saving replaces the newer "
            + "version on disk with this document. Save a copy instead to keep both."
        alert.addButton(withTitle: "Overwrite").hasDestructiveAction = true
        alert.addButton(withTitle: "Save As…")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertSecondButtonReturn:
            DispatchQueue.main.async { [weak self] in self?.saveAs(nil) }
            return false
        default:
            return false
        }
    }

    /// A save or save-as argument that only says "force" ("!" too).
    static func isForceOnly(_ argument: String?) -> Bool {
        let tokens = (argument ?? "").split(separator: " ").map(String.init)
        return !tokens.isEmpty && tokens.allSatisfy { $0 == "force" || $0 == "!" }
    }
}
