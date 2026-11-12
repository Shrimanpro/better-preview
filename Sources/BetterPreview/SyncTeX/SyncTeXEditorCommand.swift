import Foundation

/// `set synctex-editor-command`: zathura-style placeholders `%{input}`,
/// `%{line}` and `%{column}`, run through `/bin/sh -c`.
///
/// Substituted values are shell-quoted for the context they land in, so
/// both `nvim +%{line} %{input}` and `code -g "%{input}:%{line}"` work with
/// any file name (spaces, quotes, `$`, backticks).
enum SyncTeXEditorCommand {
    /// The shell command line for a template and a source location.
    static func expand(_ template: String, source: SyncTeXSource) -> String {
        let values = [
            "input": source.path,
            "line": String(source.line),
            "column": String(max(source.column, 1)),
        ]
        var out = ""
        var quote: Character?   // nil, "'" or "\""
        var escaped = false
        var i = template.startIndex
        while i < template.endIndex {
            let c = template[i]
            if c == "%", !escaped,
               let (name, end) = placeholder(in: template, at: i), let value = values[name] {
                out += quoted(value, inside: quote)
                i = end
                continue
            }
            out.append(c)
            if escaped {
                escaped = false
            } else if c == "\\" && quote != "'" {
                escaped = true
            } else if c == "'" || c == "\"" {
                if quote == nil { quote = c } else if quote == c { quote = nil }
            }
            i = template.index(after: i)
        }
        return out
    }

    /// `%{name}` starting at `index`: the name and the index after `}`.
    private static func placeholder(in s: String, at index: String.Index) -> (String, String.Index)? {
        let rest = s[index...]
        guard rest.hasPrefix("%{"), let close = rest.firstIndex(of: "}") else { return nil }
        let name = String(rest[rest.index(index, offsetBy: 2)..<close])
        guard name.allSatisfy({ $0.isLetter }) else { return nil }
        return (name, s.index(after: close))
    }

    /// Quotes `value` so the shell reads it back literally in the given
    /// quoting context.
    static func quoted(_ value: String, inside quote: Character?) -> String {
        switch quote {
        case "'":
            // Close, emit an escaped quote, reopen.
            return value.replacingOccurrences(of: "'", with: "'\\''")
        case "\"":
            var out = ""
            for c in value {
                if "\\\"$`".contains(c) { out.append("\\") }
                out.append(c)
            }
            return out
        default:
            return shellQuote(value)
        }
    }

    /// A single shell word for any string.
    static func shellQuote(_ value: String) -> String {
        if !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "/._-+:,@%=".contains($0)) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs `command` with `/bin/sh -c` without waiting for it. `completion`
    /// gets the exit status on the main queue.
    static func run(_ command: String, completion: (@MainActor (Int32, String) -> Void)? = nil) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        // Apps started from Finder get a minimal PATH; add the usual places
        // editors are installed so `code`, `nvim`, `subl` are found.
        var environment = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = (path.split(separator: ":").map(String.init) + extra)
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
        process.environment = environment
        // Keep the first few hundred bytes of stderr for the error message;
        // drain the rest so a chatty command never blocks on a full pipe.
        let captured = CapturedOutput()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { captured.append(data) }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated { completion?(status, captured.text) }
            }
        }
        try process.run()
    }
}

private final class CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        if data.count < 400 { data.append(chunk.prefix(400 - data.count)) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
