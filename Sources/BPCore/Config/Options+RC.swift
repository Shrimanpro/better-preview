import Foundation

private enum OptionKind {
    case bool(WritableKeyPath<Options, Bool>)
    case number(WritableKeyPath<Options, Double>, ClosedRange<Double>)
    case integer(WritableKeyPath<Options, Int>, ClosedRange<Int>)
    case text(WritableKeyPath<Options, String>)
    case fit(WritableKeyPath<Options, FitMode>)
}

private let optionTable: [(key: String, kind: OptionKind)] = [
    ("scroll-step", .number(\.scrollStep, 0...100_000)),
    ("scroll-hstep", .number(\.scrollHStep, 0...100_000)),
    ("smooth-scroll", .bool(\.smoothScroll)),
    ("scroll-duration", .number(\.scrollDuration, 0...10)),
    ("scroll-page-overlap", .number(\.scrollPageOverlap, 0...1)),
    ("zoom-step", .number(\.zoomStep, 1...10)),
    ("zoom-min", .number(\.zoomMin, 0.001...1000)),
    ("zoom-max", .number(\.zoomMax, 0.001...1000)),
    ("default-fit", .fit(\.defaultFit)),
    ("continuous", .bool(\.continuous)),
    ("dual-page", .bool(\.dualPage)),
    ("dual-page-book", .bool(\.dualPageBook)),
    ("page-padding", .number(\.pagePadding, 0...1000)),
    ("recolor", .bool(\.recolor)),
    ("recolor-keephue", .bool(\.recolorKeepHue)),
    ("trim-margins", .bool(\.trimMargins)),
    ("trim-padding", .number(\.trimPadding, 0...1000)),
    ("theme", .text(\.theme)),
    ("theme-light", .text(\.themeLight)),
    ("theme-dark", .text(\.themeDark)),
    ("statusbar", .bool(\.statusbar)),
    ("toolbar", .bool(\.toolbar)),
    ("sidebar", .bool(\.sidebar)),
    ("sidebar-width", .number(\.sidebarWidth, 0...5000)),
    ("font", .text(\.font)),
    ("font-size", .number(\.fontSize, 1...200)),
    ("key-timeout", .integer(\.keyTimeout, 0...60_000)),
    ("incremental-search", .bool(\.incrementalSearch)),
    ("search-wrap", .bool(\.searchWrap)),
    ("search-smartcase", .bool(\.searchSmartCase)),
    ("auto-reload", .bool(\.autoReload)),
    ("synctex", .bool(\.synctex)),
    ("synctex-editor-command", .text(\.synctexEditorCommand)),
    ("ocr-languages", .text(\.ocrLanguages)),
    ("pdfkit-analysis", .bool(\.pdfkitAnalysis)),
]

private let optionKinds: [String: OptionKind] =
    Dictionary(uniqueKeysWithValues: optionTable.map { ($0.key, $0.kind) })

extension Options {
    /// Every rc option name, in `DefaultConfig.rc` order.
    public static let rcKeys: [String] = optionTable.map(\.key)

    /// Sets the option named `key` from rc text, validating the value.
    public mutating func set(_ key: String, to value: String) throws {
        guard let kind = optionKinds[key] else {
            throw ConfigError("unknown option '\(key)'")
        }
        func bad(_ expected: String) -> ConfigError {
            ConfigError("invalid value '\(value)' for '\(key)': expected \(expected)")
        }
        switch kind {
        case .bool(let path):
            guard let b = Self.parseBool(value) else {
                throw bad("true/false, yes/no, on/off or 1/0")
            }
            self[keyPath: path] = b
        case .number(let path, let range):
            guard let d = Double(value), d.isFinite, range.contains(d) else {
                throw bad("a number from \(Self.format(range.lowerBound)) to \(Self.format(range.upperBound))")
            }
            self[keyPath: path] = d
        case .integer(let path, let range):
            guard let i = Int(value), range.contains(i) else {
                throw bad("an integer from \(range.lowerBound) to \(range.upperBound)")
            }
            self[keyPath: path] = i
        case .text(let path):
            self[keyPath: path] = value
        case .fit(let path):
            guard let f = FitMode(rawValue: value) else {
                throw bad(FitMode.allCases.map(\.rawValue).joined(separator: ", "))
            }
            self[keyPath: path] = f
        }
    }

    /// The current value of `key` in rc syntax, or nil for an unknown key.
    public func value(forKey key: String) -> String? {
        switch optionKinds[key] {
        case .bool(let path): return self[keyPath: path] ? "true" : "false"
        case .number(let path, _): return Self.format(self[keyPath: path])
        case .integer(let path, _): return String(self[keyPath: path])
        case .text(let path): return self[keyPath: path]
        case .fit(let path): return self[keyPath: path].rawValue
        case nil: return nil
        }
    }

    private static func parseBool(_ s: String) -> Bool? {
        switch s.lowercased() {
        case "true", "yes", "on", "1": return true
        case "false", "no", "off", "0": return false
        default: return nil
        }
    }

    private static func format(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
    }
}
