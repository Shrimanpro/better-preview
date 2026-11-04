import XCTest
@testable import BPCore

final class CommandCompleterTests: XCTestCase {
    private let ctx = CompletionContext(
        optionNames: ["scroll-step", "scroll-duration", "scroll-hstep", "zoom-step", "theme"],
        themeNames: ["nord", "dracula", "gruvbox", "catppuccin-mocha"])

    private func complete(_ s: String, dir: @escaping (String) -> [String] = { _ in [] }) -> [String] {
        CommandCompleter.complete(s, context: ctx, listDirectory: dir)
    }

    func testCommandPrefix() {
        XCTAssertEqual(complete("th"), ["theme "])
        XCTAssertEqual(complete("page-"), [
            "page-delete ", "page-export ", "page-insert ", "page-insert-blank ", "page-next ",
            "page-previous ", "page-rotate-ccw ", "page-rotate-cw ",
        ])
    }

    func testCanonicalBeforeAliases() {
        let r = complete("n")
        XCTAssertTrue(r.contains("n "))
        let canonicalMax = r.lastIndex { ActionName(rawValue: String($0.dropLast())) != nil } ?? -1
        let aliasMin = r.firstIndex { ActionName(rawValue: String($0.dropLast())) == nil } ?? Int.max
        XCTAssertLessThan(canonicalMax, aliasMin)
    }

    func testCommandFuzzyFallback() {
        let r = complete("pgn")
        XCTAssertTrue(r.contains("page-next "))
        XCTAssertEqual(complete("zzzz"), [])
    }

    func testEmptyInputListsAll() {
        XCTAssertGreaterThan(complete("").count, ActionName.allCases.count)
    }

    func testSetOptions() {
        XCTAssertEqual(complete("set sc"),
                       ["set scroll-duration ", "set scroll-hstep ", "set scroll-step "])
        XCTAssertEqual(complete("set zs"), ["set zoom-step "])
        XCTAssertEqual(complete("set scroll-step 1"), [])
    }

    func testThemes() {
        XCTAssertEqual(complete("theme no"), ["theme nord"])
        XCTAssertEqual(complete("colo d"), ["colo dracula"])
        XCTAssertEqual(complete("theme cm"), ["theme catppuccin-mocha"])
        XCTAssertEqual(complete("theme ").count, 4)
    }

    func testUnknownCommandNoCompletion() {
        XCTAssertEqual(complete("nonsense x"), [])
        XCTAssertEqual(complete("zoom 1"), [])
    }

    func testPathCompletion() {
        var asked: [String] = []
        let lister: (String) -> [String] = { dir in
            asked.append(dir)
            return ["notes.pdf", "Notes/", "other.pdf", ".hidden", "node/"]
        }
        XCTAssertEqual(complete("open no", dir: lister), ["open node/", "open notes.pdf", "open Notes/"].sorted())
        XCTAssertEqual(asked, ["."])
        XCTAssertEqual(complete("open sub/no", dir: lister), ["open sub/node/", "open sub/notes.pdf", "open sub/Notes/"].sorted())
        XCTAssertEqual(asked.last, "sub")
        XCTAssertEqual(complete("source ", dir: lister).count, 4)  // hidden excluded
        XCTAssertEqual(complete("o .h", dir: lister), ["o .hidden"])
    }

    func testPathTildeExpansion() {
        var asked = ""
        _ = complete("open ~/Doc") { asked = $0; return [] }
        XCTAssertEqual(asked, NSHomeDirectory())
        XCTAssertEqual(complete("open ~"), ["open ~/"])
    }

    func testPathCommands() {
        let lister: (String) -> [String] = { _ in ["a.pdf"] }
        for cmd in ["open", "e", "source", "so", "save-as", "page-insert", "w", "write"] {
            XCTAssertEqual(complete("\(cmd) a", dir: lister), ["\(cmd) a.pdf"], cmd)
        }
        XCTAssertEqual(complete("zoom a", dir: lister), [])
    }
}
