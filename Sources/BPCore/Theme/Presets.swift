import Foundation

/// Built-in themes. `base` is the page paper color, `surface` the window
/// background, `overlay` the selection/highlight row.
enum Presets {
    private static func make(
        _ name: String, dark: Bool, base: StaticString, surface: StaticString, overlay: StaticString,
        text: StaticString, subtext: StaticString, accent: StaticString,
        yellow: StaticString, orange: StaticString, red: StaticString
    ) -> Theme {
        Theme(name: name, isDark: dark, base: RGBA(base), surface: RGBA(surface), overlay: RGBA(overlay),
              text: RGBA(text), subtext: RGBA(subtext), accent: RGBA(accent),
              yellow: RGBA(yellow), orange: RGBA(orange), red: RGBA(red))
    }

    static let all: [Theme] = [
        Theme.fallbackDark,
        Theme.fallbackLight,
        make("catppuccin-latte", dark: false, base: "#eff1f5", surface: "#e6e9ef", overlay: "#ccd0da",
             text: "#4c4f69", subtext: "#6c6f85", accent: "#1e66f5",
             yellow: "#df8e1d", orange: "#fe640b", red: "#d20f39"),
        make("catppuccin-frappe", dark: true, base: "#303446", surface: "#292c3c", overlay: "#414559",
             text: "#c6d0f5", subtext: "#a5adce", accent: "#8caaee",
             yellow: "#e5c890", orange: "#ef9f76", red: "#e78284"),
        make("catppuccin-macchiato", dark: true, base: "#24273a", surface: "#1e2030", overlay: "#363a4f",
             text: "#cad3f5", subtext: "#a5adcb", accent: "#8aadf4",
             yellow: "#eed49f", orange: "#f5a97f", red: "#ed8796"),
        make("catppuccin-mocha", dark: true, base: "#1e1e2e", surface: "#181825", overlay: "#313244",
             text: "#cdd6f4", subtext: "#a6adc8", accent: "#89b4fa",
             yellow: "#f9e2af", orange: "#fab387", red: "#f38ba8"),
        make("gruvbox-dark", dark: true, base: "#282828", surface: "#1d2021", overlay: "#3c3836",
             text: "#ebdbb2", subtext: "#a89984", accent: "#83a598",
             yellow: "#fabd2f", orange: "#fe8019", red: "#fb4934"),
        make("gruvbox-light", dark: false, base: "#fbf1c7", surface: "#ebdbb2", overlay: "#d5c4a1",
             text: "#3c3836", subtext: "#7c6f64", accent: "#076678",
             yellow: "#b57614", orange: "#af3a03", red: "#9d0006"),
        make("nord", dark: true, base: "#2e3440", surface: "#272c36", overlay: "#3b4252",
             text: "#e5e9f0", subtext: "#d8dee9", accent: "#88c0d0",
             yellow: "#ebcb8b", orange: "#d08770", red: "#bf616a"),
        make("tokyo-night", dark: true, base: "#1a1b26", surface: "#16161e", overlay: "#292e42",
             text: "#c0caf5", subtext: "#a9b1d6", accent: "#7aa2f7",
             yellow: "#e0af68", orange: "#ff9e64", red: "#f7768e"),
        make("tokyo-night-day", dark: false, base: "#e1e2e7", surface: "#d0d5e3", overlay: "#c4c8da",
             text: "#3760bf", subtext: "#6172b0", accent: "#2e7de9",
             yellow: "#8c6c3e", orange: "#b15c00", red: "#f52a65"),
        make("dracula", dark: true, base: "#282a36", surface: "#21222c", overlay: "#44475a",
             text: "#f8f8f2", subtext: "#6272a4", accent: "#bd93f9",
             yellow: "#f1fa8c", orange: "#ffb86c", red: "#ff5555"),
        make("solarized-dark", dark: true, base: "#002b36", surface: "#00212b", overlay: "#073642",
             text: "#93a1a1", subtext: "#839496", accent: "#268bd2",
             yellow: "#b58900", orange: "#cb4b16", red: "#dc322f"),
        make("solarized-light", dark: false, base: "#fdf6e3", surface: "#eee8d5", overlay: "#ddd6c1",
             text: "#586e75", subtext: "#657b83", accent: "#268bd2",
             yellow: "#b58900", orange: "#cb4b16", red: "#dc322f"),
        make("rose-pine", dark: true, base: "#191724", surface: "#1f1d2e", overlay: "#26233a",
             text: "#e0def4", subtext: "#908caa", accent: "#c4a7e7",
             yellow: "#f6c177", orange: "#ebbcba", red: "#eb6f92"),
        make("rose-pine-moon", dark: true, base: "#232136", surface: "#2a273f", overlay: "#393552",
             text: "#e0def4", subtext: "#908caa", accent: "#c4a7e7",
             yellow: "#f6c177", orange: "#ea9a97", red: "#eb6f92"),
        make("rose-pine-dawn", dark: false, base: "#faf4ed", surface: "#fffaf3", overlay: "#f2e9e1",
             text: "#575279", subtext: "#797593", accent: "#907aa9",
             yellow: "#ea9d34", orange: "#d7827e", red: "#b4637a"),
    ]
}
