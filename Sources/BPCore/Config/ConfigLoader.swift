import Foundation

public enum ConfigLoader {
    /// Parses `DefaultConfig.rc`, then the user rc at `userRCPath` if `readFile`
    /// returns text for it. `readFile` takes an absolute, tilde-expanded path.
    public static func load(userRCPath: String = DefaultConfig.userConfigPath,
                            readFile: (String) -> String? = ConfigLoader.readFromDisk) -> Config {
        withoutActuallyEscaping(readFile) { readFile in
            var parser = RCParser(readFile: readFile)
            parser.parse(DefaultConfig.rc, file: "<default>", stack: [])
            let path = (userRCPath as NSString).expandingTildeInPath
            if let text = readFile(path) {
                parser.parse(text, file: path, stack: [path])
            }
            return parser.config
        }
    }

    /// Layers the rc file at `path` on top of `base` (what `:source <file>`
    /// does): its `set` / `map` / `unmap` / theme statements win, everything
    /// else in `base` stays. Problems are appended to `base.diagnostics`.
    public static func overlay(_ base: Config, path: String,
                               readFile: (String) -> String? = ConfigLoader.readFromDisk) -> Config {
        withoutActuallyEscaping(readFile) { readFile in
            var parser = RCParser(readFile: readFile)
            parser.config = base
            let expanded = (path as NSString).expandingTildeInPath
            if let text = readFile(expanded) {
                parser.parse(text, file: expanded, stack: [expanded])
            } else {
                parser.config.diagnostics.append(
                    ConfigDiagnostic(file: expanded, line: 0, message: "cannot read \(expanded)"))
            }
            return parser.config
        }
    }

    public static func readFromDisk(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

extension Config {
    /// Applies one rc statement at runtime (from the `:` command line), e.g.
    /// "set recolor true" or "map J page-next". Only `set`, `map` and `unmap`
    /// are accepted. Throws `ConfigError` describing the problem.
    public mutating func apply(statement: String) throws {
        var sc = RCScanner(Substring(statement))
        guard let command = try sc.word() else { return }
        switch command {
        case "set": try rcSet(&sc)
        case "map": try rcMap(&sc)
        case "unmap": try rcUnmap(&sc)
        default: throw ConfigError("unknown command '\(command)'")
        }
    }
}
