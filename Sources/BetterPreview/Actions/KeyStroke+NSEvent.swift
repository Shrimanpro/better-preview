import AppKit
import BPCore

extension KeyStroke {
    /// Named keys by the scalar AppKit reports in `charactersIgnoringModifiers`.
    private static let specialKeys: [UInt32: String] = {
        var m: [UInt32: String] = [
            0x1B: "Esc", 0x09: "Tab", 0x20: "Space", 0x0D: "Return", 0x03: "Return",
            0x7F: "Backspace", 0x08: "Backspace",
        ]
        let named: [(NSEvent.SpecialKey, String)] = [
            (.deleteForward, "Delete"), (.upArrow, "Up"), (.downArrow, "Down"),
            (.leftArrow, "Left"), (.rightArrow, "Right"), (.home, "Home"), (.end, "End"),
            (.pageUp, "PageUp"), (.pageDown, "PageDown"),
        ]
        for (k, name) in named { m[UInt32(k.rawValue)] = name }
        for n in 0..<20 { m[UInt32(NSEvent.SpecialKey.f1.rawValue + n)] = "F\(n + 1)" }
        return m
    }()

    /// The canonical stroke for a key-down event (see `KeyStroke`), or nil for
    /// events without a usable key (pure modifiers, dead keys). Caps lock,
    /// numeric-pad and function flags are ignored.
    init?(event: NSEvent) {
        guard event.type == .keyDown, let base = event.charactersIgnoringModifiers,
              let scalar = base.unicodeScalars.first else { return nil }
        let flags = event.modifierFlags
        var mods: Modifiers = []
        if flags.contains(.control) { mods.insert(.ctrl) }
        if flags.contains(.option) { mods.insert(.alt) }
        if flags.contains(.command) { mods.insert(.cmd) }
        if flags.contains(.shift) { mods.insert(.shift) }

        if event.keyCode == 49 { self.init("Space", mods); return }  // kVK_Space
        if scalar.value == 0x19 {  // backtab: Shift+Tab
            self.init("Tab", mods.union(.shift))
            return
        }
        if let name = Self.specialKeys[scalar.value] {
            self.init(name, mods)
            return
        }

        let shift = mods.contains(.shift)
        mods.remove(.shift)
        let key: String?
        if mods.isEmpty {
            // Plain typing: shift is folded into the character. A dead key has no characters.
            guard event.characters?.isEmpty == false else { return nil }
            key = event.characters(byApplyingModifiers: shift ? .shift : [])
        } else if let unshifted = event.characters(byApplyingModifiers: []),
                  let c = unshifted.first, c.isLetter && c.isCased {
            // Ctrl/Alt/Cmd + letter: base letter, lowercase, shift kept explicitly.
            if shift { mods.insert(.shift) }
            key = unshifted.lowercased()
        } else {
            key = event.characters(byApplyingModifiers: shift ? .shift : [])
        }
        guard let key, key.count == 1,
              !key.unicodeScalars.contains(where: { $0.properties.generalCategory == .control
                  || (0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        self.init(key, mods)
    }
}
