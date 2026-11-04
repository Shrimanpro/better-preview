import XCTest
@testable import BPCore

final class ConfigParserTests: XCTestCase {
    private func parse(_ text: String, files: [String: String] = [:]) -> Config {
        var parser = RCParser(readFile: { files[$0] })
        parser.parse(text, file: "/rc", stack: ["/rc"])
        return parser.config
    }

    private func binding(_ c: Config, _ keys: String, _ mode: Mode = .normal) -> Action? {
        c.bindings.first { $0.keys == keys && $0.mode == mode }?.action
    }

    func testDefaultsParseCleanlyAndMatchOptions() {
        let c = ConfigLoader.load(readFile: { _ in nil })
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options, Options())
        XCTAssertFalse(c.bindings.isEmpty)
        XCTAssertEqual(binding(c, "o"), Action(.enterCommand, "open "))
        XCTAssertEqual(binding(c, "<Space>o"), Action(.openPalette))
        XCTAssertEqual(binding(c, "j", .presentation), Action(.pageNext))
        XCTAssertEqual(binding(c, "'"), Action(.markJump))
        XCTAssertEqual(binding(c, ":"), Action(.enterCommand))
        let keys = c.bindings.map { "\($0.mode)\($0.keys)" }
        XCTAssertEqual(keys.count, Set(keys).count)
    }

    func testUserRCOverridesDefaults() {
        let c = ConfigLoader.load(userRCPath: "/u/rc", readFile: {
            $0 == "/u/rc" ? "set scroll-step 10\nmap j page-next\nunmap k\n" : nil
        })
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options.scrollStep, 10)
        XCTAssertEqual(binding(c, "j"), Action(.pageNext))
        XCTAssertNil(binding(c, "k"))
        XCTAssertEqual(c.bindings.last?.keys, "j")
    }

    func testCommentsBlankLinesAndQuotes() {
        let c = parse("""
        # whole line
           # indented comment

        set scroll-step 12 # trailing
        set font "Fira Code # not a comment"
        set synctex-editor-command "say \\"hi\\" \\\\ there"
        map x goto-page 5 # note
        map o enter-command "open " # quoted arg
        map <C-x> enter-command
        """)
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options.scrollStep, 12)
        XCTAssertEqual(c.options.font, "Fira Code # not a comment")
        XCTAssertEqual(c.options.synctexEditorCommand, #"say "hi" \ there"#)
        XCTAssertEqual(binding(c, "x"), Action(.gotoPage, "5"))
        XCTAssertEqual(binding(c, "o"), Action(.enterCommand, "open "))
        XCTAssertEqual(binding(c, "<C-x>"), Action(.enterCommand))
    }

    func testEmptyQuotedValueAndUnquotedMultiWordValue() {
        let c = parse("set font \"\"\nset synctex-editor-command nvim --remote +%{line} %{input}\n")
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options.font, "")
        XCTAssertEqual(c.options.synctexEditorCommand, "nvim --remote +%{line} %{input}")
    }

    func testKeyTokensVerbatim() {
        let c = parse("""
        map <Space> scroll-page-down
        map ' mark-jump
        map ` mark-jump
        map : enter-command
        map / search-forward
        map ? search-backward
        map + zoom-in
        map = zoom-reset
        map <C-d> scroll-half-down
        map [ page-previous
        map "#" goto-first
        """)
        XCTAssertEqual(c.diagnostics, [])
        for k in ["<Space>", "'", "`", ":", "/", "?", "+", "=", "<C-d>", "[", "#"] {
            XCTAssertNotNil(binding(c, k), k)
        }
    }

    func testModes() {
        let c = parse("map [presentation] x page-next\nmap [insert] <Esc> abort\nmap [normal] y copy\nunmap [presentation] x\n")
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertNil(binding(c, "x", .presentation))
        XCTAssertEqual(binding(c, "<Esc>", .insert), Action(.abort))
        XCTAssertEqual(binding(c, "y", .normal), Action(.copy))
    }

    func testReplaceMovesToEndAndUnmapRemoves() {
        let c = parse("map a fit-page\nmap b fit-width\nmap a zoom-in\nmap [presentation] a page-next\nmap c copy\nunmap c\n")
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.bindings.map(\.keys), ["b", "a", "a"])
        XCTAssertEqual(binding(c, "a"), Action(.zoomIn))
        XCTAssertNil(binding(c, "c"))
        // Unmapping something absent is not an error.
        XCTAssertEqual(parse("unmap zzz").diagnostics, [])
    }

    func testDiagnosticsWithLineNumbers() {
        let c = parse("""
        set scroll-step 5
        set scroll-step fast
        bogus line
        map j not-an-action
        map [weird] j scroll-down
        set accent notacolor
        set
        set font "open
        map
        theme-end
        set unknown-option 1
        set scroll-step 7
        """)
        XCTAssertEqual(c.diagnostics.map(\.line), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
        XCTAssertTrue(c.diagnostics.allSatisfy { $0.file == "/rc" })
        XCTAssertTrue(c.diagnostics[0].message.contains("scroll-step"))
        XCTAssertEqual(c.options.scrollStep, 7)
    }

    func testIncludes() {
        let files = [
            "/cfg/a.rc": "set scroll-step 21\ninclude sub/b.rc\n",
            "/cfg/sub/b.rc": "map z zoom-in\ninclude ../c.rc\n",
            "/cfg/c.rc": "set scroll-hstep 22\n",
        ]
        let c = parse("include /cfg/a.rc\nset zoom-step 1.5\n", files: files)
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options.scrollStep, 21)
        XCTAssertEqual(c.options.scrollHStep, 22)
        XCTAssertEqual(binding(c, "z"), Action(.zoomIn))
        XCTAssertEqual(c.options.zoomStep, 1.5)
    }

    func testIncludeRelativeToIncludingFileAndMissing() {
        var p = RCParser(readFile: { $0 == "/home/me/extra" ? "set sidebar-width 99\n" : nil })
        p.parse("include extra\ninclude missing\n", file: "/home/me/rc", stack: ["/home/me/rc"])
        XCTAssertEqual(p.config.options.sidebarWidth, 99)
        XCTAssertEqual(p.config.diagnostics.map(\.line), [2])
        XCTAssertEqual(p.config.diagnostics.first?.file, "/home/me/rc")
    }

    func testIncludeCycle() {
        let files = ["/a": "set scroll-step 1\ninclude /b\n", "/b": "include /a\nset scroll-hstep 2\n"]
        let c = parse("include /a\n", files: files)
        XCTAssertEqual(c.options.scrollStep, 1)
        XCTAssertEqual(c.options.scrollHStep, 2)
        XCTAssertEqual(c.diagnostics.count, 1)
        XCTAssertEqual(c.diagnostics[0].file, "/b")
        XCTAssertEqual(c.diagnostics[0].line, 1)
        XCTAssertTrue(c.diagnostics[0].message.contains("cycle"))
    }

    func testIncludeDepthLimit() {
        var files: [String: String] = [:]
        for i in 1...12 { files["/f\(i)"] = "include /f\(i + 1)\n" }
        files["/f13"] = "set scroll-step 1\n"
        let c = parse("include /f1\n", files: files)
        XCTAssertEqual(c.diagnostics.count, 1)
        XCTAssertTrue(c.diagnostics[0].message.contains("deeper"))
        XCTAssertEqual(c.options.scrollStep, Options().scrollStep)
    }

    func testThemeBlocks() {
        let c = parse("""
        set accent #112233
        theme-define mine dark
          set default-bg #000000
          set accent #ff0000 # comment
        theme-end
        theme-define paper light
        theme-end
        theme-define nordish dark from nord
          set accent #abcdef
        theme-end
        set default-fg #fff
        """)
        XCTAssertEqual(c.diagnostics, [])
        let mine = c.customThemes["mine"]!
        XCTAssertEqual(mine.name, "mine")
        XCTAssertTrue(mine.isDark)
        XCTAssertEqual(mine.defaultBg, RGBA("#000000"))
        XCTAssertEqual(mine.accent, RGBA("#ff0000"))
        XCTAssertEqual(mine.defaultFg, Theme.fallbackDark.defaultFg)
        var light = Theme.fallbackLight
        light.name = "paper"
        XCTAssertEqual(c.customThemes["paper"], light)
        let nordish = c.customThemes["nordish"]!
        XCTAssertEqual(nordish.accent, RGBA("#abcdef"))
        XCTAssertEqual(nordish.defaultFg, ThemeRegistry.builtin["nord"]!.defaultFg)
        // Overrides outside blocks stay global and do not leak into themes.
        XCTAssertEqual(c.themeOverrides, ["accent": RGBA("#112233"), "default-fg": RGBA("#ffffff")])
        XCTAssertEqual(c.options, Options())
    }

    func testThemeBlockErrors() {
        let c = parse("""
        theme-define x
        theme-define x purple
        theme-define y dark from nothing
        theme-define open dark
        set scroll-step 3
        map j scroll-down
        set bogus #fff
        set accent nope
        """)
        XCTAssertEqual(c.diagnostics.map(\.line), [1, 2, 3, 5, 6, 7, 8, 8])
        XCTAssertEqual(c.diagnostics.last?.message.contains("theme-define 'open'"), true)
        XCTAssertNotNil(c.customThemes["open"])
        XCTAssertEqual(c.options, Options())
        XCTAssertTrue(c.bindings.isEmpty)
    }

    func testOverlayLayersOnTopOfCurrentConfig() throws {
        var base = ConfigLoader.load(readFile: { _ in nil })
        try base.apply(statement: "set recolor true")
        try base.apply(statement: "map J goto-page 3")
        let files = ["/extra.rc": "set scroll-step 7\nmap K page-next\nmap J page-previous\ntheme-define mine dark\ntheme-end\n"]
        let c = ConfigLoader.overlay(base, path: "/extra.rc", readFile: { files[$0] })
        XCTAssertTrue(c.options.recolor, "earlier settings survive")
        XCTAssertEqual(c.options.scrollStep, 7)
        XCTAssertEqual(binding(c, "K"), Action(.pageNext))
        XCTAssertEqual(binding(c, "J"), Action(.pagePrevious), "overlay wins")
        XCTAssertEqual(binding(c, "j"), binding(base, "j"), "default bindings survive")
        XCTAssertNotNil(c.customThemes["mine"])
        XCTAssertEqual(c.diagnostics, [])

        let missing = ConfigLoader.overlay(base, path: "/nope.rc", readFile: { _ in nil })
        XCTAssertTrue(missing.options.recolor)
        XCTAssertEqual(missing.diagnostics.count, 1)
        let bad = ConfigLoader.overlay(base, path: "/bad", readFile: { _ in "set recolor maybe\nset scroll-step 9" })
        XCTAssertEqual(bad.options.scrollStep, 9)
        XCTAssertEqual(bad.diagnostics.map(\.line), [1])
    }

    func testRuntimeApply() throws {
        var c = ConfigLoader.load(readFile: { _ in nil })
        try c.apply(statement: "set recolor true")
        XCTAssertTrue(c.options.recolor)
        try c.apply(statement: "map J goto-page 3")
        XCTAssertEqual(binding(c, "J"), Action(.gotoPage, "3"))
        try c.apply(statement: "map [presentation] J page-next")
        try c.apply(statement: "unmap J")
        XCTAssertNil(binding(c, "J"))
        XCTAssertEqual(binding(c, "J", .presentation), Action(.pageNext))
        try c.apply(statement: "set accent #123456")
        XCTAssertEqual(c.themeOverrides["accent"], RGBA("#123456"))
        try c.apply(statement: "   ")
        try c.apply(statement: "# nothing")
        XCTAssertThrowsError(try c.apply(statement: "set recolor maybe")) {
            XCTAssertTrue($0 is ConfigError)
        }
        XCTAssertThrowsError(try c.apply(statement: "map q nonsense"))
        XCTAssertThrowsError(try c.apply(statement: "frobnicate"))
        XCTAssertThrowsError(try c.apply(statement: "include /x"))
        XCTAssertEqual(c.diagnostics, [])
    }

    func testBindingsUniqueAfterManyOverrides() {
        let text = (0..<50).map { "map a \($0 % 2 == 0 ? "zoom-in" : "zoom-out")" }.joined(separator: "\n")
        let c = parse(text)
        XCTAssertEqual(c.bindings.count, 1)
        XCTAssertEqual(c.bindings[0].action.name, .zoomOut)
    }

    func testCRLFLines() {
        let c = parse("set scroll-step 9\r\nmap x copy\r\n")
        XCTAssertEqual(c.diagnostics, [])
        XCTAssertEqual(c.options.scrollStep, 9)
        XCTAssertEqual(binding(c, "x"), Action(.copy))
    }
}
