import AppKit
import BPCore

/// The single dispatch path for keys, the input bar, menus and DebugScript:
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

        // Marks and jumps
        case .markSet: setMark(argument)
        case .markJump: jumpToMark(argument)
        case .jumpBack: jump(count: count) { $0.back(from: $1) }
        case .jumpForward: jump(count: count) { list, _ in list.forward() }

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

    // MARK: Marks and jumps

    private func setMark(_ name: String?) {
        guard let c = name?.first, marks.set(c, content.currentPosition) else {
            return showMessage("Invalid mark name", isError: true)
        }
    }

    /// `'x` jumps to mark x; `''` returns to where the last jump started.
    private func jumpToMark(_ name: String?) {
        guard let c = name?.first else { return }
        let target = c == "'" || c == "`" ? lastJumpOrigin : marks.get(c)
        guard let target else { return showMessage("Mark \(c) not set", isError: true) }
        recordJump(from: content.currentPosition)
        content.go(to: target, animated: true)
    }

    private func jump(count: Int, _ step: (inout JumpList, DocumentPosition) -> DocumentPosition?) {
        let current = content.currentPosition
        var target: DocumentPosition?
        for _ in 0..<count {
            guard let next = step(&jumpList, current) else { break }
            target = next
        }
        if let target { content.go(to: target, animated: true) }
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
