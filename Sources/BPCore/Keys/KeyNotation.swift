public struct KeyNotationError: Error, Hashable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// Vim key notation: `gg`, `<C-d>`, `<Space>o`, `<S-Tab>`, `<lt>`.
///
/// Modifier prefixes and key names inside `<...>` are case-insensitive:
/// `C-` ctrl, `A-`/`M-` alt, `D-` cmd, `S-` shift. Aliases: `<CR>`/`<Enter>`
/// = Return, `<BS>` = Backspace, `<Del>` = Delete, `<Bar>` = `|`,
/// `<lt>` = `<`, `<gt>` = `>`, `<Bslash>` = `\`. A `<` with no closing `>`
/// is a literal `<`.
public enum KeyNotation {
    public static func parse(_ keys: String) throws -> [KeyStroke] {
        guard !keys.isEmpty else { throw KeyNotationError(message: "empty key sequence") }
        var strokes: [KeyStroke] = []
        var i = keys.startIndex
        while i < keys.endIndex {
            let c = keys[i]
            if c == "<", let close = keys[keys.index(after: i)...].firstIndex(of: ">") {
                strokes.append(try parseBracket(String(keys[keys.index(after: i)..<close])))
                i = keys.index(after: close)
            } else {
                strokes.append(try canonical(String(c), []))
                i = keys.index(after: i)
            }
        }
        return strokes
    }

    /// Canonical spelling: modifiers in `C-A-D-S-` order, named keys as in
    /// `KeyStroke.namedKeys`, `<` as `<lt>`.
    public static func format(_ strokes: [KeyStroke]) -> String {
        var out = ""
        for s in strokes { append(s, to: &out) }
        return out
    }

    private static func append(_ s: KeyStroke, to out: inout String) {
        let isNamed = KeyStroke.namedKeys.contains(s.key)
        if s.modifiers.isEmpty && !isNamed {
            out += s.key == "<" ? "<lt>" : s.key
            return
        }
        out += "<"
        if s.modifiers.contains(.ctrl) { out += "C-" }
        if s.modifiers.contains(.alt) { out += "A-" }
        if s.modifiers.contains(.cmd) { out += "D-" }
        if s.modifiers.contains(.shift) { out += "S-" }
        switch s.key {
        case "<": out += "lt"
        case ">": out += "gt"
        default: out += s.key
        }
        out += ">"
    }

    private static let modifierPrefixes: [Character: KeyStroke.Modifiers] = [
        "c": .ctrl, "a": .alt, "m": .alt, "d": .cmd, "s": .shift,
    ]

    /// Lowercased name -> canonical key.
    private static let names: [String: String] = {
        var n: [String: String] = [
            "cr": "Return", "enter": "Return", "bs": "Backspace", "del": "Delete",
            "lt": "<", "gt": ">", "bar": "|", "bslash": "\\",
        ]
        for k in KeyStroke.namedKeys { n[k.lowercased()] = k }
        return n
    }()

    /// Parses the inside of `<...>`.
    private static func parseBracket(_ inner: String) throws -> KeyStroke {
        var mods: KeyStroke.Modifiers = []
        var rest = Substring(inner)
        while rest.count > 2, rest.dropFirst().first == "-",
              let m = modifierPrefixes[Character(rest.first!.lowercased())] {
            mods.insert(m)
            rest = rest.dropFirst(2)
        }
        if rest.count == 1 { return try canonical(String(rest), mods) }
        guard let key = names[rest.lowercased()] else {
            throw KeyNotationError(message: "unknown key <\(inner)>")
        }
        return try canonical(key, mods)
    }

    private static func canonical(_ key: String, _ mods: KeyStroke.Modifiers) throws -> KeyStroke {
        if key == " " { return KeyStroke("Space", mods) }
        if KeyStroke.namedKeys.contains(key) { return KeyStroke(key, mods) }
        let c = key.first!
        guard !c.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw KeyNotationError(message: "control character in key sequence")
        }
        var mods = mods
        let isLetter = c.isLetter && c.isCased
        if mods.isDisjoint(with: [.ctrl, .alt, .cmd]) {
            guard mods.contains(.shift) else { return KeyStroke(key, []) }
            guard isLetter else { throw shiftError(key) }
            return KeyStroke(key.uppercased(), [])
        }
        guard isLetter else {
            if mods.contains(.shift) { throw shiftError(key) }
            return KeyStroke(key, mods)
        }
        if c.isUppercase { mods.insert(.shift) }
        return KeyStroke(key.lowercased(), mods)
    }

    private static func shiftError(_ key: String) -> KeyNotationError {
        KeyNotationError(message: "<S-\(key)>: write the shifted character itself instead")
    }
}
