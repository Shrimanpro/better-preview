import AppKit
import PDFKit

/// Asks for the password of an encrypted PDF while it is being opened.
///
/// A window does not exist yet at that point, so this is an app-modal alert,
/// not a sheet. `BP_PDF_PASSWORD` supplies the password without asking
/// (headless runs); a wrong one then cancels instead of asking again.
@MainActor
enum PasswordPrompt {
    private static var cancelled = false
    /// A password known for the next open of a file (Save As reopening the
    /// copy it just wrote, with the same encryption). Used once.
    static var knownPassword: (url: URL, password: String)?

    /// True once if the last open ended because the user cancelled the
    /// password alert (the caller must not report an error).
    static func takeCancellation() -> Bool {
        defer { cancelled = false }
        return cancelled
    }

    static func ask(fileName: String, wrong: Bool) -> String? {
        ask(title: "“\(fileName)” is password protected",
            text: wrong ? "That password is not correct. Try again." : "Enter the password to open it.",
            button: "Open")
    }

    /// The owner password, needed to remove or change the encryption of a
    /// document whose owner restricts it.
    static func askOwner(fileName: String, wrong: Bool) -> String? {
        ask(title: "“\(fileName)” has owner restrictions",
            text: wrong ? "That is not the owner password. Try again."
                : "Enter the owner password to remove or change its encryption.",
            button: "Unlock")
    }

    /// Unlocks `document` with owner rights when it has restrictions that a
    /// copy without its encryption would drop. `BP_PDF_OWNER_PASSWORD`
    /// answers headless runs; scripted runs never show the alert.
    static func ensureOwnerAccess(_ document: PDFDocument, fileName: String) -> Bool {
        guard PDFExporter.needsOwnerPassword(document) else { return true }
        if let preset = ProcessInfo.processInfo.environment["BP_PDF_OWNER_PASSWORD"] {
            return document.unlock(withPassword: preset) && document.permissionsStatus == .owner
        }
        guard ProcessInfo.processInfo.environment["BP_SCRIPT"] == nil else { return false }
        var wrong = false
        while let password = askOwner(fileName: fileName, wrong: wrong) {
            if document.unlock(withPassword: password), document.permissionsStatus == .owner { return true }
            wrong = true
        }
        return false
    }

    private static func ask(title: String, text: String, button: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Password"
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}

extension BPDocument {
    /// Opens `url`, asking for the password when it is encrypted. Nil when
    /// the file cannot be read or the user cancels (after which
    /// `PasswordPrompt.takeCancellation()` returns true).
    @MainActor
    static func openUnlocking(url: URL, renderState: PageRenderState) -> (document: BPDocument, password: String?)? {
        guard let document = BPDocument(url: url, renderState: renderState) else { return nil }
        guard document.isLocked else { return (document, nil) }
        // An unencrypted-for-opening file (owner password only) is not locked.
        var wrong = false
        if let known = PasswordPrompt.knownPassword, known.url.standardizedFileURL == url.standardizedFileURL {
            PasswordPrompt.knownPassword = nil
            if document.unlock(withPassword: known.password) { return (document, known.password) }
        }
        if let preset = ProcessInfo.processInfo.environment["BP_PDF_PASSWORD"] {
            return document.unlock(withPassword: preset) ? (document, preset) : nil
        }
        while let password = PasswordPrompt.ask(fileName: url.lastPathComponent, wrong: wrong) {
            if document.unlock(withPassword: password) { return (document, password) }
            wrong = true
        }
        PasswordPrompt.markCancelled()
        return nil
    }

    /// A reload of a file that was unlocked before: reuse the password.
    static func openReloading(url: URL, renderState: PageRenderState, password: String?) -> BPDocument? {
        guard let document = BPDocument(url: url, renderState: renderState) else { return nil }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else { return nil }
        }
        return document
    }
}

extension PasswordPrompt {
    fileprivate static func markCancelled() { cancelled = true }
}
