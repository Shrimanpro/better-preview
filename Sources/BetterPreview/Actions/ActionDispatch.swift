import AppKit
import BPCore

/// The single dispatch path for keys, the input bar and menus:
/// window features first, then window-level actions, then the document.
extension DocumentWindowController {
    func dispatch(_ invocation: ActionInvocation) {
        for feature in features where feature.handle(invocation, in: self) { return }
        let argument = invocation.action.argument
        let count = max(1, invocation.count ?? 1)
        switch invocation.action.name {
        // Input bar
        case .enterCommand: openCommandBar(.command, text: argument ?? "")
        case .searchForward: openCommandBar(.searchForward)
        case .searchBackward: openCommandBar(.searchBackward)
        case .abort: abort()

        // Configuration
        case .setOption: setOption(argument)
        case .mapKey: applyStatement("map", argument)
        case .unmapKey: applyStatement("unmap", argument)
        case .setTheme: setTheme(argument)
        case .sourceConfig: ConfigController.shared.source(argument.map { resolvePath($0).path })

        // Files (ActionDispatch+Files)
        case .open: open(argument)
        case .reload: reload()
        case .close: window?.performClose(nil)
        case .quit: NSApp.terminate(nil)
        case .save: saveInPlace(force: Self.isForceOnly(argument))
        case .saveAs: saveAs(argument)

        // Chrome
        case .toggleStatusbar: contentView.statusBarVisible.toggle()
        case .toggleFullscreen: window?.toggleFullScreen(nil)
        case .toggleSidebar, .toggleToolbar:
            showMessage("\(invocation.action.name.rawValue): not implemented yet", isError: true)


        // Editing
        case .undo: undo(redo: false)
        case .redo: undo(redo: true)

        default:
            if !content.perform(invocation) {
                if invocation.action.name == .annotationDelete, content is PDFDocumentController {
                    return showMessage("No annotation selected", isError: true)
                }
                showMessage("\(invocation.action.name.rawValue): not available", isError: true)
            }
        }
    }

    /// Esc: drop pending keys, the message and the search highlight, and let
    /// the document cancel tools or selections.
    private func abort() {
        engineStorage?.reset()
        keyTimer?.invalidate()
        keyTimer = nil
        clearMessage()
        content.perform(ActionInvocation(.searchClear))
        content.perform(ActionInvocation(.abort))
        refreshStatus()
    }

    // MARK: Configuration

    private func setOption(_ argument: String?) {
        guard let argument, !argument.isEmpty else {
            return showMessage("set: missing option name", isError: true)
        }
        do {
            if let shown = try ConfigController.shared.query(option: argument) {
                showMessage(shown, isError: false)
            } else {
                try ConfigController.shared.apply(statement: "set " + argument)
            }
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func applyStatement(_ command: String, _ argument: String?) {
        do {
            try ConfigController.shared.apply(statement: command + " " + (argument ?? ""))
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func setTheme(_ name: String?) {
        guard let name else { return showMessage("theme = \(theme.name)", isError: false) }
        do {
            try ConfigController.shared.setTheme(name)
        } catch {
            showMessage(error.localizedDescription, isError: true)
        }
    }

    private func undo(redo: Bool) {
        let manager = content.undoManager
        if redo ? manager.canRedo : manager.canUndo {
            redo ? manager.redo() : manager.undo()
        } else {
            showMessage(redo ? "Already at newest change" : "Already at oldest change", isError: false)
        }
    }
}
