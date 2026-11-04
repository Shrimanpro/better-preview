import Foundation

/// Reads words and values from one rc line. `#` starts a comment where a word
/// would start, or after whitespace inside a value; never inside quotes.
struct RCScanner {
    private(set) var rest: Substring

    init(_ line: Substring) {
        rest = line
    }

    private mutating func skipSpaces() {
        rest = rest.drop { $0 == " " || $0 == "\t" }
    }

    /// The next whitespace-delimited word (or quoted string), nil at end of line
    /// or comment.
    mutating func word() throws -> String? {
        skipSpaces()
        guard let first = rest.first, first != "#" else { return nil }
        if first == "\"" { return try quoted() }
        let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
        defer { rest = rest[end...] }
        return String(rest[..<end])
    }

    /// The rest of the line as one value: a quoted string, or raw text up to a
    /// trailing comment. With `hashStartsValue`, a leading `#` is part of the
    /// value (colors); otherwise it begins a comment.
    mutating func remainder(hashStartsValue: Bool = false) throws -> String? {
        skipSpaces()
        guard let first = rest.first else { return nil }
        if first == "\"" {
            let value = try quoted()
            skipSpaces()
            if let c = rest.first, c != "#" {
                throw ConfigError("unexpected text after closing quote")
            }
            return value
        }
        if first == "#" && !hashStartsValue { return nil }
        var end = rest.endIndex
        var previous = first
        for i in rest.indices.dropFirst() {
            let c = rest[i]
            if c == "#" && previous.isWhitespace { end = i; break }
            previous = c
        }
        let value = rest[..<end].trimmingCharacters(in: .whitespaces)
        rest = rest[end...]
        return value.isEmpty ? nil : value
    }

    private mutating func quoted() throws -> String {
        var out = ""
        var i = rest.index(after: rest.startIndex)
        while i < rest.endIndex {
            let c = rest[i]
            i = rest.index(after: i)
            if c == "\"" {
                rest = rest[i...]
                return out
            }
            if c == "\\", i < rest.endIndex, rest[i] == "\"" || rest[i] == "\\" {
                out.append(rest[i])
                i = rest.index(after: i)
            } else {
                out.append(c)
            }
        }
        throw ConfigError("unterminated quoted string")
    }
}
