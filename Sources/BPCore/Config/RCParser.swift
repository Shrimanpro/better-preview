import Foundation

/// Statement-level semantics shared by file parsing and runtime `apply`.
extension Config {
    mutating func rcSet(_ sc: inout RCScanner) throws {
        guard let key = try sc.word() else { throw ConfigError("set: missing option name") }
        guard let value = try sc.remainder(hashStartsValue: true) else {
            throw ConfigError("set \(key): missing value")
        }
        if Theme.colorKeys[key] != nil {
            themeOverrides[key] = try Self.color(value, key: key)
        } else {
            try options.set(key, to: value)
        }
    }

    mutating func rcMap(_ sc: inout RCScanner) throws {
        let (mode, keys) = try Self.modeAndKeys(&sc, statement: "map")
        guard let name = try sc.word() else { throw ConfigError("map \(keys): missing action") }
        guard let action = ActionName(rawValue: name) else {
            throw ConfigError("map \(keys): unknown action '\(name)'")
        }
        let argument = try sc.remainder()
        bind(KeyBinding(mode: mode, keys: keys, action: Action(action, argument)))
    }

    mutating func rcUnmap(_ sc: inout RCScanner) throws {
        let (mode, keys) = try Self.modeAndKeys(&sc, statement: "unmap")
        bindings.removeAll { $0.mode == mode && $0.keys == keys }
    }

    /// Adds a binding, replacing any earlier one for the same mode and keys.
    mutating func bind(_ binding: KeyBinding) {
        bindings.removeAll { $0.mode == binding.mode && $0.keys == binding.keys }
        bindings.append(binding)
    }

    static func color(_ value: String, key: String) throws -> RGBA {
        guard let c = RGBA(hex: value) else {
            throw ConfigError("invalid color '\(value)' for '\(key)': expected #rgb, #rrggbb or #rrggbbaa")
        }
        return c
    }

    private static func modeAndKeys(_ sc: inout RCScanner, statement: String) throws -> (Mode, String) {
        guard var word = try sc.word() else { throw ConfigError("\(statement): missing keys") }
        var mode = Mode.normal
        if word.count >= 3, word.hasPrefix("["), word.hasSuffix("]") {
            let name = String(word.dropFirst().dropLast())
            guard let m = Mode(rawValue: name) else {
                throw ConfigError("\(statement): unknown mode '\(name)'")
            }
            mode = m
            guard let keys = try sc.word() else { throw ConfigError("\(statement): missing keys") }
            word = keys
        }
        return (mode, word)
    }
}

/// Parses rc text into a `Config`, following includes and theme blocks.
struct RCParser {
    static let maxIncludeDepth = 8

    var config = Config()
    let readFile: (String) -> String?
    private var block: Theme?

    init(readFile: @escaping (String) -> String?) {
        self.readFile = readFile
    }

    /// `stack` holds the files currently being parsed (for cycle detection).
    mutating func parse(_ text: String, file: String, stack: [String]) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        for (index, line) in lines.enumerated() {
            do {
                try exec(line, file: file, stack: stack)
            } catch {
                diagnose(error, file: file, line: index + 1)
            }
        }
        if let open = block {
            block = nil
            config.customThemes[open.name] = open
            diagnose(ConfigError("theme-define '\(open.name)' without theme-end"), file: file, line: lines.count)
        }
    }

    private mutating func diagnose(_ error: Error, file: String, line: Int) {
        let message = (error as? ConfigError)?.message ?? error.localizedDescription
        config.diagnostics.append(ConfigDiagnostic(file: file, line: line, message: message))
    }

    private mutating func exec(_ line: Substring, file: String, stack: [String]) throws {
        var sc = RCScanner(line)
        guard let command = try sc.word() else { return }
        if block != nil { return try execInBlock(command, &sc) }
        switch command {
        case "set": try config.rcSet(&sc)
        case "map": try config.rcMap(&sc)
        case "unmap": try config.rcUnmap(&sc)
        case "include": try include(&sc, from: file, stack: stack)
        case "theme-define": try beginTheme(&sc)
        case "theme-end": throw ConfigError("theme-end without theme-define")
        default: throw ConfigError("unknown command '\(command)'")
        }
    }

    private mutating func execInBlock(_ command: String, _ sc: inout RCScanner) throws {
        switch command {
        case "theme-end":
            let theme = block!
            block = nil
            config.customThemes[theme.name] = theme
        case "set":
            guard let key = try sc.word() else { throw ConfigError("set: missing color name") }
            guard let path = Theme.colorKeys[key] else {
                throw ConfigError("unknown color '\(key)' in theme-define")
            }
            guard let value = try sc.remainder(hashStartsValue: true) else {
                throw ConfigError("set \(key): missing value")
            }
            block![keyPath: path] = try Config.color(value, key: key)
        default:
            throw ConfigError("'\(command)' is not allowed inside theme-define (missing theme-end?)")
        }
    }

    private mutating func beginTheme(_ sc: inout RCScanner) throws {
        guard let name = try sc.word(), !name.isEmpty else {
            throw ConfigError("theme-define: missing theme name")
        }
        guard let kind = try sc.word(), kind == "dark" || kind == "light" else {
            throw ConfigError("theme-define \(name): expected 'dark' or 'light'")
        }
        let isDark = kind == "dark"
        var theme = isDark ? Theme.fallbackDark : Theme.fallbackLight
        if let from = try sc.word() {
            guard from == "from", let base = try sc.word() else {
                throw ConfigError("theme-define \(name): expected 'from <theme>'")
            }
            guard let source = config.customThemes[base] ?? ThemeRegistry.builtin[base] else {
                throw ConfigError("theme-define \(name): unknown theme '\(base)'")
            }
            theme = source
        }
        theme.name = name
        theme.isDark = isDark
        block = theme
    }

    private mutating func include(_ sc: inout RCScanner, from file: String, stack: [String]) throws {
        guard let raw = try sc.remainder() else { throw ConfigError("include: missing path") }
        var path = (raw as NSString).expandingTildeInPath
        if !path.hasPrefix("/") {
            path = ((file as NSString).deletingLastPathComponent as NSString).appendingPathComponent(path)
        }
        path = (path as NSString).standardizingPath
        guard !stack.contains(path) else { throw ConfigError("include cycle: \(path)") }
        guard stack.count < Self.maxIncludeDepth else {
            throw ConfigError("include nested deeper than \(Self.maxIncludeDepth) levels: \(path)")
        }
        guard let text = readFile(path) else { throw ConfigError("cannot read included file \(path)") }
        parse(text, file: path, stack: stack + [path])
    }
}
