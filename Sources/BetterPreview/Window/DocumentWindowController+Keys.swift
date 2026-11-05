import AppKit
import BPCore

/// Key routing. Every key-down of the window arrives in `handleKeyEvent`
/// (via `DocumentWindow`) and is converted to a `KeyStroke`; `handleKey` is
/// the single entry point after conversion.
///
/// What is intercepted:
/// - command mode: the input bar's special keys (Return, Esc, Tab, history,
///   Ctrl-w/u ...); everything else goes to its text field.
/// - a text view has focus (form field, annotation editor): insert mode;
///   only Esc is taken, to return focus to the document.
/// - normal / presentation mode: the keymap engine decides; unbound keys
///   (including unbound Cmd shortcuts) continue to the responder chain and
///   the menus.
extension DocumentWindowController {
    var engine: KeymapEngine {
        if let engine = engineStorage { return engine }
        let bindings = AppEnvironment.shared.config.bindings
        let engine = KeymapEngine(bindings: bindings)
        engineStorage = engine
        engineBindings = bindings
        return engine
    }

    /// Bindings changed: the engine is rebuilt on the next key.
    func discardKeyEngine() {
        keyTimer?.invalidate()
        keyTimer = nil
        engineStorage = nil
        engineBindings = []
        refreshStatus()
    }

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let stroke = KeyStroke(event: event) else { return false }
        return handleKey(stroke)
    }

    /// Returns true when the stroke was consumed.
    @discardableResult
    func handleKey(_ stroke: KeyStroke) -> Bool {
        if mode == .command {
            return commandBarStorage?.handle(stroke) ?? false
        }
        if let text = window?.firstResponder as? NSText {
            if mode != .insert { setMode(.insert) }
            guard stroke == .escape else { return false }
            // Esc during input-method composition cancels the composition.
            if (text as? NSTextView)?.hasMarkedText() == true { return false }
            setMode(baseMode)
            focusDocument()
            return true
        }
        if mode == .insert { setMode(baseMode) }

        if message != nil { clearMessage() }
        let hadPending = engineStorage?.pendingDisplay.isEmpty == false
        let results = engine.feed(stroke, mode: mode)
        restartKeyTimer()
        var handled = true
        for result in results {
            switch result {
            case .invoke(let invocation): dispatch(invocation)
            case .unhandled: handled = false
            case .pending, .cancelled: break
            }
        }
        if hadPending || engineStorage?.pendingDisplay.isEmpty == false { refreshStatus() }
        return handled
    }

    /// Per the engine's contract: after every feed, stop the timer and start
    /// a new one only while an ambiguous sequence is pending.
    private func restartKeyTimer() {
        keyTimer?.invalidate()
        keyTimer = nil
        guard engine.needsTimeout else { return }
        let interval = Double(options.keyTimeout) / 1000
        keyTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyTimerFired() }
        }
    }

    private func keyTimerFired() {
        keyTimer = nil
        let result = engine.timeout()
        restartKeyTimer()
        if case .invoke(let invocation) = result { dispatch(invocation) }
        refreshStatus()
    }
}
