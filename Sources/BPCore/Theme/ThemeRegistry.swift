import Foundation

public enum ThemeRegistry {
    public static let builtin: [String: Theme] =
        Dictionary(uniqueKeysWithValues: Presets.all.map { ($0.name, $0) })

    /// Sorted names of the built-in themes.
    public static var builtinNames: [String] { builtin.keys.sorted() }

    /// The active theme: `options.theme`, or themeLight/themeDark when it is
    /// "auto". Custom themes shadow builtins; unknown names fall back to the
    /// default for the appearance. `themeOverrides` are applied last.
    public static func resolve(config: Config, systemIsDark: Bool) -> Theme {
        let options = config.options
        let name = options.theme == "auto" ? (systemIsDark ? options.themeDark : options.themeLight) : options.theme
        var theme = config.customThemes[name] ?? builtin[name]
            ?? (systemIsDark ? Theme.fallbackDark : Theme.fallbackLight)
        for (key, color) in config.themeOverrides {
            if let path = Theme.colorKeys[key] { theme[keyPath: path] = color }
        }
        return theme
    }

    /// Builtin and custom theme names, sorted and unique.
    public static func names(in config: Config) -> [String] {
        Set(builtin.keys).union(config.customThemes.keys).sorted()
    }
}
