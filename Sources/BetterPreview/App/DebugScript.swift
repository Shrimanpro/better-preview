import AppKit
import BPCore

/// Scripted driver for automated checks. Set the environment variable
/// BP_SCRIPT to a `;`-separated list of steps; they run against the first
/// window, one every BP_SCRIPT_DELAY seconds (default 0.4):
///
///   <action> [argument]      e.g.  scroll-down   |  goto-page 40  |  theme nord
///   <count>:<action> [arg]   e.g.  5:scroll-down
///   keys <vim keys>          e.g.  keys 5j  |  keys <C-d>  |  keys gg
///                            strokes go through the same path as real key events
///   post <letters/digits>    posts real NSEvent key-downs (exercises the window's
///                            event interception and KeyStroke conversion)
///   type <text>              types into the open input bar
///   enter | escape           Return / Esc, through the key path
///   cmd <command line>       runs a `:` command line, e.g. cmd set scroll-step 200
///   snapshot <file.png>      renders the window's content view in-process,
///                            PDF pages included (see DebugSnapshot)
///   sleep <seconds>
///   quit
///
/// After each step a line is written to stderr:
///   STATUS step="..." page=3/500 pos=2:0.512 zoom=1.250 dirty=false mode=normal flags=a,b
///          detail="..." message="..." pending="..." bar="..." theme=nord
@MainActor
enum DebugScript {
    static func runIfRequested(window: @escaping () -> DocumentWindowController?) {
        guard let script = ProcessInfo.processInfo.environment["BP_SCRIPT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["BP_SCRIPT_DELAY"] ?? "") ?? 0.4
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        run(steps[...], delay: delay, window: window)
    }

    private static func run(_ steps: ArraySlice<String>, delay: Double,
                            window: @escaping () -> DocumentWindowController?) {
        guard let step = steps.first else { return }
        var wait = delay
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : nil
        if parts[0] == "quit" {
            NSApp.terminate(nil)
            return
        } else if parts[0] == "sleep" {
            wait = Double(argument ?? "") ?? delay
        } else if let controller = window() {
            perform(parts[0], argument, on: controller)
            // Steps run from timers, not events; an event closes the undo
            // group the step opened, so each step undoes on its own.
            if let event = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(event, atStart: false)
            }
        } else {
            log("ERROR no window")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            if let controller = window() { log(statusLine(step, controller)) }
            run(steps.dropFirst(), delay: delay, window: window)
        }
    }

    private static func perform(_ command: String, _ argument: String?, on controller: DocumentWindowController) {
        switch command {
        case "keys":
            do {
                for stroke in try KeyNotation.parse(argument ?? "") { controller.handleKey(stroke) }
            } catch {
                log("ERROR \(error)")
            }
        case "post": post(argument ?? "", to: controller)
        case "type":
            guard controller.mode == .command else { return log("ERROR input bar not open") }
            controller.commandBar.type(argument ?? "")
        case "enter": controller.handleKey(KeyStroke("Return"))
        case "escape": controller.handleKey(.escape)
        case "cmd": controller.runCommandLine(argument ?? "")
        case "snapshot": snapshot(controller.contentView, to: argument ?? "snapshot.png")
        default:
            var name = command
            var count: Int?
            if let colon = name.firstIndex(of: ":"), let n = Int(name[..<colon]) {
                count = n
                name = String(name[name.index(after: colon)...])
            }
            guard let action = ActionName(rawValue: name) else { return log("ERROR unknown action \(name)") }
            controller.dispatch(ActionInvocation(action, argument, count: count))
        }
    }

    /// ANSI key codes; `characters(byApplyingModifiers:)` needs the real code.
    private static let keyCodes: [Character: UInt16] = {
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        let digits: [UInt16] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]
        var map: [Character: UInt16] = [:]
        for (i, code) in letters.enumerated() { map[Character(UnicodeScalar(UInt8(97 + i)))] = code }
        for (i, code) in digits.enumerated() { map[Character(UnicodeScalar(UInt8(48 + i)))] = code }
        return map
    }()

    private static func post(_ text: String, to controller: DocumentWindowController) {
        guard let window = controller.window else { return }
        for c in text {
            guard let code = keyCodes[Character(c.lowercased())] else { return log("ERROR cannot post \(c)") }
            let shift: NSEvent.ModifierFlags = c.isUppercase ? .shift : []
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: shift, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: String(c),
                charactersIgnoringModifiers: String(c).lowercased(), isARepeat: false, keyCode: code)
            if let event { NSApp.postEvent(event, atStart: false) }
        }
    }

    private static func snapshot(_ view: NSView, to path: String) {
        guard let png = DebugSnapshot.png(of: view) else { return log("ERROR snapshot failed") }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            log("ERROR \(error)")
        }
    }

    private static func statusLine(_ step: String, _ controller: DocumentWindowController) -> String {
        let s = controller.content.status
        let p = controller.content.currentPosition
        let bar = controller.mode == .command ? controller.commandBar.kind.prefix + controller.commandBar.text : ""
        return "STATUS step=\"\(step)\" page=\(s.page)/\(s.pageCount) "
            + "pos=\(p.page):\(String(format: "%.3f", p.y)) pct=\(s.position.map(String.init) ?? "-") zoom=\(String(format: "%.3f", s.zoom)) "
            + "dirty=\(controller.content.isDirty) mode=\(controller.mode.rawValue) "
            + "flags=\(s.flags.joined(separator: ",")) detail=\"\(s.detail)\" "
            + "message=\"\(controller.message ?? "")\" pending=\"\(controller.engineStorage?.pendingDisplay ?? "")\" "
            + "bar=\"\(bar)\" theme=\(AppEnvironment.shared.theme.name)"
    }

    private static func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
}
