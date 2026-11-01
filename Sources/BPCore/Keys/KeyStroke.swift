/// One key press in canonical form, shared by the rc notation (`KeyNotation`)
/// and the AppKit event conversion so that both compare equal.
///
/// Canonical form:
/// - `key` is either a single printable character as typed (`"j"`, `"J"`,
///   `"?"`, `"<"`) or a named key (see `KeyStroke.namedKeys`).
/// - For printable characters shift is folded into the character and the
///   `.shift` modifier is not set (`J`, `?`, `+`).
/// - With ctrl/alt/cmd, letters are stored lowercase; an explicit shift is
///   kept as `.shift` (`<C-S-d>`). Shift is never set on a non-letter character.
/// - Named keys keep shift (`<S-Tab>`, `<S-Space>`).
public struct KeyStroke: Hashable, Sendable {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let ctrl = Modifiers(rawValue: 1 << 0)
        public static let alt = Modifiers(rawValue: 1 << 1)
        public static let cmd = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    public var key: String
    public var modifiers: Modifiers

    /// Does not canonicalize; build strokes with `KeyNotation.parse` or the
    /// AppKit initializer unless the form is known to be canonical.
    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Every named key, in canonical spelling.
    public static let namedKeys: Set<String> = Set(
        ["Esc", "Tab", "Space", "Return", "Backspace", "Delete", "Up", "Down", "Left", "Right",
         "Home", "End", "PageUp", "PageDown"] + (1...20).map { "F\($0)" })

    public static let escape = KeyStroke("Esc")

    /// The character, when `key` is a single character rather than a named key.
    public var character: Character? {
        key.count == 1 ? key.first : nil
    }

    /// The value 0-9 when this is an unmodified ASCII digit.
    var digit: Int? {
        guard modifiers.isEmpty else { return nil }
        var utf8 = key.utf8.makeIterator()
        guard let b = utf8.next(), utf8.next() == nil, (0x30...0x39).contains(b) else { return nil }
        return Int(b - 0x30)
    }
}
