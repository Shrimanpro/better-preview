import XCTest
@testable import BPCore

final class CommandParserTests: XCTestCase {
    private func parse(_ s: String) throws -> ActionInvocation { try CommandParser.parse(s) }
    private func fails(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> CommandError? {
        do { _ = try CommandParser.parse(s); XCTFail("expected throw: \(s)", file: file, line: line); return nil }
        catch { return error as? CommandError }
    }

    func testEmptyThrows() {
        XCTAssertNotNil(fails(""))
        XCTAssertNotNil(fails("   "))
    }

    func testBareNumber() throws {
        XCTAssertEqual(try parse("42"), ActionInvocation(.gotoPage, count: 42))
        XCTAssertEqual(try parse("  7  "), ActionInvocation(.gotoPage, count: 7))
        XCTAssertNotNil(fails("0"))
    }

    func testCountPrefix() throws {
        XCTAssertEqual(try parse("3 page-next"), ActionInvocation(.pageNext, count: 3))
        XCTAssertEqual(try parse("5 next"), ActionInvocation(.pageNext, count: 5))
    }

    func testCanonicalNames() throws {
        for name in ActionName.allCases where name != .quit && name != .gotoPage && name != .zoomSet {
            XCTAssertEqual(try parse(name.rawValue), ActionInvocation(name))
        }
    }

    func testArgumentAndTrim() throws {
        XCTAssertEqual(try parse("  open   ~/a b.pdf  "), ActionInvocation(.open, "~/a b.pdf"))
        XCTAssertEqual(try parse("open"), ActionInvocation(.open))
    }

    func testQuotedArgument() throws {
        XCTAssertEqual(try parse(#"open "my file.pdf""#), ActionInvocation(.open, "my file.pdf"))
        XCTAssertEqual(try parse(#"open "a \"b\" \\c""#), ActionInvocation(.open, #"a "b" \c"#))
        // Not entirely wrapped: left alone.
        XCTAssertEqual(try parse(#"open "a" b"#), ActionInvocation(.open, #""a" b"#))
        XCTAssertEqual(try parse(#"open "unterminated"#), ActionInvocation(.open, #""unterminated"#))
        XCTAssertEqual(try parse(#"open """#), ActionInvocation(.open))
    }

    func testAliases() throws {
        let expected: [String: ActionName] = [
            "q": .close, "quit": .close, "qa": .quit, "qall": .quit, "w": .save, "write": .save,
            "e": .open, "edit": .open, "o": .open, "r": .reload, "p": .print, "hardcopy": .print,
            "hl": .annotateHighlight, "highlight": .annotateHighlight,
            "nohl": .searchClear, "nohlsearch": .searchClear, "so": .sourceConfig,
            "colorscheme": .setTheme, "colo": .setTheme, "first": .gotoFirst, "last": .gotoLast,
            "next": .pageNext, "n": .pageNext, "prev": .pagePrevious, "previous": .pagePrevious,
            "N": .pagePrevious, "fs": .toggleFullscreen, "fullscreen": .toggleFullscreen,
            "pres": .togglePresentation, "presentation": .togglePresentation,
            "sidebar": .toggleSidebar, "toolbar": .toggleToolbar, "recolor": .toggleRecolor,
            "trim": .toggleTrim, "dual": .toggleDualPage, "rotate": .rotateCW,
        ]
        for (alias, action) in expected {
            XCTAssertEqual(try parse(alias), ActionInvocation(action), alias)
        }
    }

    func testWriteWithArgumentIsSaveAs() throws {
        XCTAssertEqual(try parse("w out.pdf"), ActionInvocation(.saveAs, "out.pdf"))
        XCTAssertEqual(try parse("write out.pdf"), ActionInvocation(.saveAs, "out.pdf"))
        XCTAssertEqual(try parse("w"), ActionInvocation(.save))
    }

    func testGotoPage() throws {
        XCTAssertEqual(try parse("goto-page 12"), ActionInvocation(.gotoPage, "12"))
        XCTAssertEqual(try parse("g 012"), ActionInvocation(.gotoPage, "12"))
        XCTAssertEqual(try parse("2 goto"), ActionInvocation(.gotoPage, count: 2))
        XCTAssertNotNil(fails("g abc"))
        XCTAssertNotNil(fails("g 0"))
        XCTAssertNotNil(fails("g -3"))
        XCTAssertNotNil(fails("goto"))
    }

    func testZoomSet() throws {
        XCTAssertEqual(try parse("zoom 150"), ActionInvocation(.zoomSet, "150"))
        XCTAssertEqual(try parse("zoom 150%"), ActionInvocation(.zoomSet, "150"))
        XCTAssertEqual(try parse("zoom-set 112.5%"), ActionInvocation(.zoomSet, "112.5"))
        XCTAssertNotNil(fails("zoom"))
        XCTAssertNotNil(fails("zoom abc"))
        XCTAssertNotNil(fails("zoom 0"))
    }

    func testPassThroughArguments() throws {
        XCTAssertEqual(try parse("set scroll-step 100"), ActionInvocation(.setOption, "scroll-step 100"))
        XCTAssertEqual(try parse("map j scroll-down"), ActionInvocation(.mapKey, "j scroll-down"))
        XCTAssertEqual(try parse("unmap j"), ActionInvocation(.unmapKey, "j"))
        XCTAssertEqual(try parse("theme nord"), ActionInvocation(.setTheme, "nord"))
        XCTAssertEqual(try parse("so ~/.rc"), ActionInvocation(.sourceConfig, "~/.rc"))
    }

    func testUnknownCommandSuggestions() throws {
        let e = try XCTUnwrap(fails("foo"))
        XCTAssertEqual(e.message, "Not a command: foo")
        XCTAssertLessThanOrEqual(e.suggestions.count, 3)
        let e2 = try XCTUnwrap(fails("opn"))
        XCTAssertTrue(e2.suggestions.contains("open"))
        let e3 = try XCTUnwrap(fails("togg"))
        XCTAssertEqual(e3.suggestions.count, 3)
        XCTAssertTrue(e3.suggestions.allSatisfy { $0.hasPrefix("togg") })
        XCTAssertTrue(e2.errorDescription?.contains("Did you mean") == true)
    }

    func testCommandNames() {
        let names = CommandParser.commandNames
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(Set(names).count, names.count)
        XCTAssertTrue(names.contains("page-next"))
        XCTAssertTrue(names.contains("colorscheme"))
    }

    func testTokenizingActionsKeepQuotes() throws {
        XCTAssertEqual(try parse(#"save-as "a b.pdf""#), ActionInvocation(.saveAs, #""a b.pdf""#))
        XCTAssertEqual(try parse(#"w "my notes.pdf""#), ActionInvocation(.saveAs, #""my notes.pdf""#))
        XCTAssertEqual(try parse(#"export "a b.png" 72"#), ActionInvocation(.export, #""a b.png" 72"#))
        XCTAssertEqual(try parse(#"page-export 1-2 "x y.pdf""#), ActionInvocation(.pageExport, #"1-2 "x y.pdf""#))
        XCTAssertEqual(try parse("w"), ActionInvocation(.save))
        XCTAssertEqual(try parse(#"w """#), ActionInvocation(.save))
        // Other actions still unquote.
        XCTAssertEqual(try parse(#"open "my file.pdf""#), ActionInvocation(.open, "my file.pdf"))
    }

    func testSplitArguments() {
        XCTAssertEqual(CommandParser.splitArguments(#""a b.pdf" force"#), ["a b.pdf", "force"])
        XCTAssertEqual(CommandParser.splitArguments("  x   y "), ["x", "y"])
        XCTAssertEqual(CommandParser.splitArguments(#"pre"fix x"post"#), ["prefix xpost"])
        XCTAssertEqual(CommandParser.splitArguments(#""a \"q\" \\b""#), [#"a "q" \b"#])
        XCTAssertEqual(CommandParser.splitArguments(#"c:\dir"#), [#"c:\dir"#])
        XCTAssertEqual(CommandParser.splitArguments(#""""#), [""])
        XCTAssertEqual(CommandParser.splitArgumentWords(#""2024" png"#),
                       [.init("2024", quoted: true), .init("png", quoted: false)])
    }
}
