import XCTest
@testable import BPCore

final class ThemeTests: XCTestCase {
    private let expected = [
        "catppuccin-frappe", "catppuccin-latte", "catppuccin-macchiato", "catppuccin-mocha",
        "default-dark", "default-light", "dracula", "gruvbox-dark", "gruvbox-light", "nord",
        "rose-pine", "rose-pine-dawn", "rose-pine-moon", "solarized-dark", "solarized-light",
        "tokyo-night", "tokyo-night-day",
    ]

    func testBuiltinNames() {
        XCTAssertEqual(ThemeRegistry.builtinNames, expected)
        for (key, theme) in ThemeRegistry.builtin { XCTAssertEqual(key, theme.name) }
    }

    func testPresetBrightnessMatchesIsDark() {
        for theme in ThemeRegistry.builtin.values {
            XCTAssertEqual(theme.isDark, theme.defaultBg.luminance < 0.5, theme.name)
            XCTAssertEqual(theme.isDark, theme.recolorLightColor.luminance < 0.5, theme.name)
            XCTAssertNotEqual(theme.recolorLightColor, theme.recolorDarkColor, theme.name)
        }
    }

    func testKnownPaletteValues() {
        let mocha = ThemeRegistry.builtin["catppuccin-mocha"]!
        XCTAssertEqual(mocha.recolorLightColor, RGBA("#1e1e2e"))
        XCTAssertEqual(mocha.defaultBg, RGBA("#181825"))
        XCTAssertEqual(mocha.recolorDarkColor, RGBA("#cdd6f4"))
        XCTAssertEqual(ThemeRegistry.builtin["dracula"]!.accent, RGBA("#bd93f9"))
        XCTAssertEqual(ThemeRegistry.builtin["default-dark"], Theme.fallbackDark)
        XCTAssertEqual(ThemeRegistry.builtin["default-light"], Theme.fallbackLight)
    }

    func testResolveAuto() {
        let c = Config()
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: true).name, "catppuccin-mocha")
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: false).name, "catppuccin-latte")
    }

    func testResolveExplicitIgnoresSystem() {
        var c = Config()
        c.options.theme = "nord"
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: false).name, "nord")
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: true).name, "nord")
    }

    func testResolveUnknownFallsBack() {
        var c = Config()
        c.options.theme = "nope"
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: true), Theme.fallbackDark)
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: false), Theme.fallbackLight)
        c.options.theme = "auto"
        c.options.themeDark = "missing"
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: true), Theme.fallbackDark)
    }

    func testCustomShadowsBuiltin() {
        var custom = Theme.fallbackLight
        custom.name = "nord"
        var c = Config(customThemes: ["nord": custom])
        c.options.theme = "nord"
        XCTAssertEqual(ThemeRegistry.resolve(config: c, systemIsDark: true), custom)
    }

    func testOverridesApplied() {
        var c = Config(themeOverrides: ["accent": RGBA("#010203"), "bogus": RGBA("#ffffff")])
        c.options.theme = "dracula"
        let t = ThemeRegistry.resolve(config: c, systemIsDark: true)
        XCTAssertEqual(t.accent, RGBA("#010203"))
        XCTAssertEqual(t.defaultFg, ThemeRegistry.builtin["dracula"]!.defaultFg)
        XCTAssertEqual(t.name, "dracula")
    }

    func testNamesUniqueSorted() {
        var other = Theme.fallbackDark
        other.name = "mine"
        var shadow = other
        shadow.name = "nord"
        let names = ThemeRegistry.names(in: Config(customThemes: ["mine": other, "nord": shadow]))
        XCTAssertEqual(names, (expected + ["mine"]).sorted())
    }
}
