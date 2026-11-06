import AppKit
import BPCore

/// Owns the live configuration: loads the rc at launch, reloads it when it
/// changes on disk, follows the system appearance and applies runtime
/// `:set` / `:map` / `:unmap` / `:theme` / `:source`. Results are published
/// through `AppEnvironment.shared`.
///
/// The live config is rebuilt from layers, in order: the built-in rc, the user
/// rc, then every file sourced with `:source <path>` and every runtime
/// statement, so an edit to the rc file keeps the session's own changes.
/// `:source` without a path drops those layers and reloads the rc alone.
@MainActor
final class ConfigController {
    static let shared = ConfigController()

    /// `BP_RC` overrides the user rc path (tests, alternative setups).
    let rcPath: String = {
        let path = ProcessInfo.processInfo.environment["BP_RC"] ?? DefaultConfig.userConfigPath
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }()

    private enum Layer {
        case file(String)
        case statement(String)
    }

    private static let sessionFile = "<session>"
    private var layers: [Layer] = []
    private var watcher: FileWatcher?
    private var appearanceObservation: NSKeyValueObservation?
    /// A load-time problem waiting for the first window to show it.
    private var undeliveredMessage: String?

    private init() {}

    /// Loads the config and starts watching the rc file and the appearance.
    func start() {
        reload()
        watcher = FileWatcher(url: URL(fileURLWithPath: rcPath)) { [weak self] in self?.reload() }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in ConfigController.shared.appearanceDidChange() }
        }
    }

    // MARK: Runtime changes

    /// Applies "set …", "map …" or "unmap …" to the live config.
    func apply(statement: String) throws {
        var config = AppEnvironment.shared.config
        try config.apply(statement: statement)
        if let problem = Self.invalidBindings(in: config).first { throw ConfigError(problem) }
        layers.append(.statement(statement))
        publish(config)
    }

    /// `:set <option>` without a value, `<option>?` and `<option>!` (toggle).
    /// Returns the text to show, or nil when `argument` has a value to set.
    func query(option argument: String) throws -> String? {
        guard !argument.contains(where: \.isWhitespace) else { return nil }
        var key = argument
        let toggle = key.hasSuffix("!")
        if toggle || key.hasSuffix("?") { key.removeLast() }
        if let path = Theme.colorKeys[key] {
            guard !toggle else { throw ConfigError("cannot toggle '\(key)'") }
            return "\(key) = \(AppEnvironment.shared.theme[keyPath: path].hex)"
        }
        guard let value = AppEnvironment.shared.options.value(forKey: key) else {
            throw ConfigError("unknown option '\(key)'")
        }
        guard toggle else { return "\(key) = \(value.isEmpty ? "\"\"" : value)" }
        guard value == "true" || value == "false" else { throw ConfigError("'\(key)' is not a boolean") }
        let flipped = value == "true" ? "false" : "true"
        try apply(statement: "set \(key) \(flipped)")
        return "\(key) = \(flipped)"
    }

    func setTheme(_ name: String) throws {
        let config = AppEnvironment.shared.config
        guard name == "auto" || ThemeRegistry.names(in: config).contains(name) else {
            throw ConfigError("unknown theme '\(name)'")
        }
        try apply(statement: "set theme \(name)")
    }

    /// `:source`: reload the rc (nil), or add `path` on top of the config.
    func source(_ path: String?) {
        if let path {
            // A missing file would fail again on every later reload.
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                let text = "source: no such file \((path as NSString).abbreviatingWithTildeInPath)"
                if let window = DocumentWindowController.frontmost {
                    window.showMessage(text, isError: true)
                } else {
                    undeliveredMessage = text
                }
                return
            }
            layers.append(.file(path))
        } else {
            layers.removeAll()
        }
        reload()
    }

    /// Hands a load problem to the first window that asks.
    func takeUndeliveredMessage() -> String? {
        defer { undeliveredMessage = nil }
        return undeliveredMessage
    }

    // MARK: Loading

    private func reload() {
        var lines: [String] = []
        if FileManager.default.fileExists(atPath: rcPath) { lines.append(Self.include(rcPath)) }
        for layer in layers {
            switch layer {
            case .file(let path): lines.append(Self.include(path))
            case .statement(let statement): lines.append(statement)
            }
        }
        let session = lines.joined(separator: "\n")
        var config = ConfigLoader.load(userRCPath: Self.sessionFile) { path in
            path == Self.sessionFile ? session : ConfigLoader.readFromDisk(path)
        }
        config.diagnostics += Self.invalidBindings(in: config).map {
            ConfigDiagnostic(file: "<bindings>", line: 0, message: $0)
        }
        report(config.diagnostics)
        publish(config)
    }

    private func publish(_ config: Config) {
        AppEnvironment.shared.update(config: config, theme: Self.resolveTheme(config))
    }

    private func appearanceDidChange() {
        let config = AppEnvironment.shared.config
        let theme = Self.resolveTheme(config)
        if theme != AppEnvironment.shared.theme { AppEnvironment.shared.update(config: config, theme: theme) }
    }

    private static func resolveTheme(_ config: Config) -> Theme {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return ThemeRegistry.resolve(config: config, systemIsDark: isDark)
    }

    private static func include(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "include \"\(escaped)\""
    }

    private static func invalidBindings(in config: Config) -> [String] {
        config.bindings.compactMap { binding in
            do {
                _ = try KeyNotation.parse(binding.keys)
                return nil
            } catch {
                return "map \(binding.keys): \(error)"
            }
        }
    }

    /// Logs every diagnostic; the first one goes to the frontmost window.
    private func report(_ diagnostics: [ConfigDiagnostic]) {
        guard let first = diagnostics.first else { return }
        for d in diagnostics { NSLog("better-preview config: %@:%d: %@", d.file, d.line, d.message) }
        let file = first.file == Self.sessionFile ? ":source" : (first.file as NSString).lastPathComponent
        var text = first.line > 0 ? "\(file):\(first.line): \(first.message)" : first.message
        if diagnostics.count > 1 { text += " (+\(diagnostics.count - 1) more)" }
        if let window = DocumentWindowController.frontmost {
            window.showMessage(text, isError: true)
        } else {
            undeliveredMessage = text
        }
    }
}

extension RGBA {
    /// `#rrggbb`, or `#rrggbbaa` when not opaque.
    var hex: String {
        func byte(_ v: Double) -> String { String(format: "%02x", Int((min(max(v, 0), 1) * 255).rounded())) }
        return "#" + byte(r) + byte(g) + byte(b) + (a < 1 ? byte(a) : "")
    }
}
