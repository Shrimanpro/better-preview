import XCTest
@testable import BPCore

final class KeyNotationTests: XCTestCase {
    private func p(_ s: String) throws -> [KeyStroke] { try KeyNotation.parse(s) }
    private func roundTrip(_ s: String) throws -> String { KeyNotation.format(try p(s)) }

    func testPlainCharacters() throws {
        XCTAssertEqual(try p("gg"), [KeyStroke("g"), KeyStroke("g")])
        XCTAssertEqual(try p("J"), [KeyStroke("J")])
        XCTAssertEqual(try p("?+'`:"), ["?", "+", "'", "`", ":"].map { KeyStroke($0) })
        XCTAssertEqual(try p("z0"), [KeyStroke("z"), KeyStroke("0")])
    }

    func testModifiersAreCanonical() throws {
        XCTAssertEqual(try p("<C-d>"), [KeyStroke("d", .ctrl)])
        XCTAssertEqual(try p("<c-d>"), [KeyStroke("d", .ctrl)])
        XCTAssertEqual(try p("<C-D>"), [KeyStroke("d", [.ctrl, .shift])])
        XCTAssertEqual(try p("<C-S-d>"), [KeyStroke("d", [.ctrl, .shift])])
        XCTAssertEqual(try p("<s-c-D>"), [KeyStroke("d", [.ctrl, .shift])])
        XCTAssertEqual(try p("<A-x>"), [KeyStroke("x", .alt)])
        XCTAssertEqual(try p("<M-x>"), [KeyStroke("x", .alt)])
        XCTAssertEqual(try p("<D-s>"), [KeyStroke("s", .cmd)])
        XCTAssertEqual(try p("<C-->"), [KeyStroke("-", .ctrl)])
        XCTAssertEqual(try p("<C-?>"), [KeyStroke("?", .ctrl)])
    }

    func testShiftFoldsIntoCharacters() throws {
        XCTAssertEqual(try p("<S-j>"), [KeyStroke("J")])
        XCTAssertEqual(try p("<J>"), [KeyStroke("J")])
        XCTAssertThrowsError(try p("<S-/>"))
        XCTAssertThrowsError(try p("<C-S-/>"))
    }

    func testNamedKeys() throws {
        XCTAssertEqual(try p("<Esc>"), [.escape])
        XCTAssertEqual(try p("<esc>"), [.escape])
        XCTAssertEqual(try p("<CR>"), [KeyStroke("Return")])
        XCTAssertEqual(try p("<Enter>"), [KeyStroke("Return")])
        XCTAssertEqual(try p("<BS>"), [KeyStroke("Backspace")])
        XCTAssertEqual(try p("<Del>"), [KeyStroke("Delete")])
        XCTAssertEqual(try p("<pagedown>"), [KeyStroke("PageDown")])
        XCTAssertEqual(try p("<F20>"), [KeyStroke("F20")])
        XCTAssertEqual(try p("<S-Tab>"), [KeyStroke("Tab", .shift)])
        XCTAssertEqual(try p("<S-Space>"), [KeyStroke("Space", .shift)])
        XCTAssertEqual(try p("<Space>o"), [KeyStroke("Space"), KeyStroke("o")])
        XCTAssertEqual(try p(" "), [KeyStroke("Space")])
        XCTAssertEqual(try p("<Bar><lt><gt><Bslash>"), ["|", "<", ">", "\\"].map { KeyStroke($0) })
        XCTAssertEqual(try p("<C-lt>"), [KeyStroke("<", .ctrl)])
    }

    func testLoneAngleBracketIsLiteral() throws {
        XCTAssertEqual(try p("<"), [KeyStroke("<")])
        XCTAssertEqual(try p("<<"), [KeyStroke("<"), KeyStroke("<")])
        XCTAssertEqual(try p(">"), [KeyStroke(">")])
    }

    func testErrors() {
        XCTAssertThrowsError(try p(""))
        XCTAssertThrowsError(try p("<Foo>"))
        XCTAssertThrowsError(try p("<>"))
        XCTAssertThrowsError(try p("<F21>"))
        XCTAssertThrowsError(try p("<X-a>"))
        XCTAssertThrowsError(try p("\u{04}"))
    }

    func testFormatIsCanonical() throws {
        XCTAssertEqual(try roundTrip("<c-d>"), "<C-d>")
        XCTAssertEqual(try roundTrip("<C-D>"), "<C-S-d>")
        XCTAssertEqual(try roundTrip("<s-d-c-a-x>"), "<C-A-D-S-x>")
        XCTAssertEqual(try roundTrip("<M-x>"), "<A-x>")
        XCTAssertEqual(try roundTrip("<cr><bs><del><esc>"), "<Return><Backspace><Delete><Esc>")
        XCTAssertEqual(try roundTrip("<lt><Bar><gt>"), "<lt>|>")
        XCTAssertEqual(try roundTrip("<C-lt><C-gt>"), "<C-lt><C-gt>")
        XCTAssertEqual(try roundTrip("<S-j><space>o"), "J<Space>o")
        XCTAssertEqual(try roundTrip("gg"), "gg")
    }

    /// Every `map` line of the built-in rc parses, and format/parse round-trips.
    func testDefaultConfigBindingsParse() throws {
        var checked = 0
        for line in DefaultConfig.rc.split(separator: "\n") {
            var words = line.split(separator: " ")
            guard words.first == "map" else { continue }
            words.removeFirst()
            if words.first?.hasPrefix("[") == true { words.removeFirst() }
            let keys = String(words[0])
            let strokes = try KeyNotation.parse(keys)
            let formatted = KeyNotation.format(strokes)
            XCTAssertEqual(try KeyNotation.parse(formatted), strokes, keys)
            XCTAssertEqual(KeyNotation.format(try KeyNotation.parse(formatted)), formatted, keys)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 70)
    }
}
