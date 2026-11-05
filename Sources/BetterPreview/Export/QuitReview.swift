import AppKit

/// What happens to unsaved documents when the app quits.
@MainActor
enum QuitReview {
    /// Save All / Cancel / Discard. Windows are saved one by one; if any
    /// save fails the quit is cancelled so nothing is lost.
    static func terminateReply(for dirty: [DocumentWindowController]) -> NSApplication.TerminateReply {
        guard !dirty.isEmpty else { return .terminateNow }
        // Scripted runs cannot answer a modal alert: quit without saving.
        if ProcessInfo.processInfo.environment["BP_SCRIPT"] != nil {
            let names = dirty.map(\.content.fileURL.lastPathComponent).joined(separator: ", ")
            FileHandle.standardError.write(Data("WARN quit discards unsaved changes in \(names) (BP_SCRIPT)\n".utf8))
            return .terminateNow
        }
        let alert = NSAlert()
        if dirty.count == 1 {
            alert.messageText = "Save changes to “\(dirty[0].content.fileURL.lastPathComponent)” before quitting?"
        } else {
            alert.messageText = "You have \(dirty.count) documents with unsaved changes."
        }
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: dirty.count == 1 ? "Save" : "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save").hasDestructiveAction = true
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for controller in dirty where !controller.saveInPlace() {
                controller.showWindow(nil)
                return .terminateCancel
            }
            return .terminateNow
        case .alertThirdButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }
}
