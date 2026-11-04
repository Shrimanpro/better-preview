import XCTest
@testable import BPCore

final class FuzzyMatcherTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        let m = FuzzyMatcher.match("", in: "anything")
        XCTAssertEqual(m?.score, 0)
        XCTAssertEqual(m?.positions, [])
    }

    func testNonSubsequenceIsNil() {
        XCTAssertNil(FuzzyMatcher.match("xyz", in: "abc"))
        XCTAssertNil(FuzzyMatcher.match("ba", in: "ab"))
        XCTAssertNil(FuzzyMatcher.match("aa", in: "a"))
    }

    func testPositionsAscendingAndCorrect() throws {
        let m = try XCTUnwrap(FuzzyMatcher.match("abc", in: "a_b_c"))
        XCTAssertEqual(m.positions, [0, 2, 4])
    }

    func testSmartCase() {
        XCTAssertNotNil(FuzzyMatcher.match("abc", in: "ABC"))
        XCTAssertNil(FuzzyMatcher.match("Abc", in: "abc"))
        XCTAssertNotNil(FuzzyMatcher.match("Abc", in: "Abc"))
    }

    func testBetterPreviewBeatsPump() throws {
        let r = FuzzyMatcher.rank("bp", in: ["abc/pump.pdf", "better_preview.pdf"], key: { $0 })
        XCTAssertEqual(r.map(\.item), ["better_preview.pdf", "abc/pump.pdf"])
        XCTAssertEqual(r[0].match.positions, [0, 7])
    }

    func testFilenameBeatsDirectory() {
        let r = FuzzyMatcher.rank("main", in: ["domain/x.swift", "src/main.swift"], key: { $0 })
        XCTAssertEqual(r.first?.item, "src/main.swift")
    }

    func testConsecutiveBeatsScattered() throws {
        let a = try XCTUnwrap(FuzzyMatcher.match("abc", in: "xabcx"))
        let b = try XCTUnwrap(FuzzyMatcher.match("abc", in: "xaxbxcx"))
        XCTAssertGreaterThan(a.score, b.score)
    }

    func testWordStartAndCamelBonus() throws {
        let camel = try XCTUnwrap(FuzzyMatcher.match("fb", in: "fooBar"))
        let plain = try XCTUnwrap(FuzzyMatcher.match("fb", in: "foobar"))
        XCTAssertGreaterThan(camel.score, plain.score)
        XCTAssertEqual(camel.positions, [0, 3])
    }

    func testOptimalAlignmentNotGreedy() throws {
        // Greedy would take the first "a" (position 0) and scatter; best is the "ab" run.
        let m = try XCTUnwrap(FuzzyMatcher.match("ab", in: "a____ab"))
        XCTAssertEqual(m.positions, [5, 6])
    }

    func testRankStableTiesAndLimit() {
        let items = ["a1", "a2", "a3", "a4"]
        let r = FuzzyMatcher.rank("a", in: items, limit: 3, key: { $0 })
        XCTAssertEqual(r.map(\.item), ["a1", "a2", "a3"])
        XCTAssertTrue(FuzzyMatcher.rank("a", in: items, limit: 0, key: { $0 }).isEmpty)
    }

    func testRankKeyAndFiltering() {
        struct Item { let name: String }
        let r = FuzzyMatcher.rank("fo", in: [Item(name: "bar"), Item(name: "foo")], key: \.name)
        XCTAssertEqual(r.map(\.item.name), ["foo"])
    }

    func testRankMatchesSingleMatch() {
        let items = ["src/main.swift", "domain/x.swift", "readme.md"]
        for r in FuzzyMatcher.rank("main", in: items, key: { $0 }) {
            XCTAssertEqual(r.match.score, FuzzyMatcher.match("main", in: r.item)?.score)
            XCTAssertEqual(r.match.positions.count, 4)
        }
    }

    func testUnicodePositionsAreCharacterOffsets() throws {
        // "e" + combining acute is one Character but two scalars.
        let candidate = "e\u{301}x_y"
        let m = try XCTUnwrap(FuzzyMatcher.match("xy", in: candidate))
        XCTAssertEqual(m.positions, [1, 3])
        let n = try XCTUnwrap(FuzzyMatcher.match("é", in: "café"))
        XCTAssertEqual(n.positions, [3])
    }

    func testCaseInsensitiveUnicode() {
        XCTAssertNotNil(FuzzyMatcher.match("ünï", in: "ÜNÏcode"))
    }

    func testPerformanceSmoke() {
        let items = (0..<5000).map { "dir\($0 % 50)/sub/file_\($0)_report.pdf" }
        measure { _ = FuzzyMatcher.rank("frp", in: items, key: { $0 }) }
    }
}
