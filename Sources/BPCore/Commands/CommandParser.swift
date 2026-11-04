import Foundation

public enum CommandParser {
    /// All command names (canonical action names plus aliases), sorted.
    public static var commandNames: [String] { allNames }

    private static let allNames: [String] =
        Set(ActionName.allCases.map(\.rawValue)).union(CommandAliases.table.keys).sorted()

    /// Parses the text typed after ":" into an invocation.
    public static func parse(_ line: String) throws -> ActionInvocation {
        var rest = Substring(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !rest.isEmpty else { throw CommandError("Empty command") }

        var (word, tail) = splitWord(rest)
        var count: Int?
        if word.allSatisfy(\.isASCIIDigit) {
            guard let n = Int(word), n >= 1 else { throw CommandError("Invalid count: \(word)") }
            if tail.isEmpty { return ActionInvocation(.gotoPage, count: n) }
            count = n
            rest = tail
            (word, tail) = splitWord(rest)
        }

        guard let name = CommandAliases.resolve(String(word)) else {
            throw CommandError("Not a command: \(word)", suggestions: suggestions(for: String(word)))
        }
        var argument = unquote(tail)
        var target = name
        if name == .save, ["w", "write"].contains(word), argument != nil { target = .saveAs }
        // These split their argument into a path and options themselves and
        // understand quotes there: `save-as "a b.pdf"` must stay one path.
        if Self.tokenizingActions.contains(target), argument != nil {
            argument = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        switch target {
        case .gotoPage:
            if let arg = argument {
                guard let page = Int(arg), page >= 1 else { throw CommandError("Invalid page number: \(arg)") }
                argument = String(page)
            } else if count == nil {
                throw CommandError("goto-page needs a page number")
            }
        case .zoomSet:
            guard let arg = argument else { throw CommandError("zoom-set needs a percentage") }
            argument = try normalizePercent(arg)
        default:
            break
        }
        return ActionInvocation(target, argument, count: count)
    }

    /// Actions whose argument keeps its quotes (see `parse`).
    static let tokenizingActions: Set<ActionName> = [.saveAs, .export, .pageExport]

    /// A word of a command argument; `quoted` when any part of it was in
    /// double quotes (so it is a name, never an option keyword or number).
    public struct ArgumentWord: Equatable, Sendable {
        public var text: String
        public var quoted: Bool
        public init(_ text: String, quoted: Bool) {
            self.text = text
            self.quoted = quoted
        }
    }

    /// Splits a command argument on spaces; double quotes keep words with
    /// spaces together (inside quotes a backslash escapes the next
    /// character). `""` is an empty word.
    public static func splitArgumentWords(_ text: String) -> [ArgumentWord] {
        var words: [ArgumentWord] = [], current = ""
        var inQuotes = false, started = false, escaped = false, wasQuoted = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
            } else if inQuotes && ch == "\\" {
                escaped = true
            } else if ch == "\"" {
                inQuotes.toggle()
                started = true
                wasQuoted = true
            } else if ch.isWhitespace && !inQuotes {
                if started { words.append(ArgumentWord(current, quoted: wasQuoted)) }
                current = ""
                started = false
                wasQuoted = false
            } else {
                current.append(ch)
                started = true
            }
        }
        if escaped { current.append("\\") }
        if started { words.append(ArgumentWord(current, quoted: wasQuoted)) }
        return words
    }

    /// `splitArgumentWords` without the quote information.
    public static func splitArguments(_ text: String) -> [String] { splitArgumentWords(text).map(\.text) }

    // MARK: - Helpers

    private static func splitWord(_ s: Substring) -> (Substring, Substring) {
        guard let space = s.firstIndex(where: \.isWhitespace) else { return (s, "") }
        let tail = s[space...].drop(while: \.isWhitespace)
        return (s[..<space], tail)
    }

    /// Trims; strips surrounding double quotes (with `\"` and `\\` escapes)
    /// when the whole text is one quoted string. Empty -> nil.
    private static func unquote(_ s: Substring) -> String? {
        let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("\""), text.count >= 2 else { return text.isEmpty ? nil : text }
        var out = ""
        var escaped = false
        var chars = text.dropFirst().makeIterator()
        while let c = chars.next() {
            if escaped {
                out.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                // Closing quote: valid only if nothing follows it.
                return chars.next() == nil ? (out.isEmpty ? nil : out) : text
            } else {
                out.append(c)
            }
        }
        return text
    }

    private static func normalizePercent(_ arg: String) throws -> String {
        var text = arg
        if text.hasSuffix("%") { text.removeLast() }
        guard let v = Double(text.trimmingCharacters(in: .whitespaces)), v.isFinite, v > 0 else {
            throw CommandError("Invalid zoom: \(arg)")
        }
        return v == v.rounded() && v < 1e9 ? String(Int(v)) : String(v)
    }

    private static func suggestions(for word: String) -> [String] {
        let lower = word.lowercased()
        let prefixed = allNames.filter { $0.hasPrefix(lower) }
        let near = allNames
            .compactMap { name -> (String, Int)? in
                let d = editDistance(lower, name)
                return d <= 2 && !name.hasPrefix(lower) ? (name, d) : nil
            }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map(\.0)
        var seen = Set<String>()
        return Array((prefixed + near).filter { seen.insert($0).inserted }.prefix(3))
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        var row = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var diag = row[0]
            row[0] = i
            for j in 1...max(b.count, 1) where !b.isEmpty {
                let up = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diag + (a[i - 1] == b[j - 1] ? 0 : 1))
                diag = up
            }
        }
        return row[b.count]
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
