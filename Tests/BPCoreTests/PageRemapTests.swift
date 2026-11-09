import XCTest
@testable import BPCore

final class PageRemapTests: XCTestCase {
    private func p(_ n: Int, y: Double = 0.5) -> DocumentPosition { DocumentPosition(page: n, x: 0.1, y: y) }

    func testIdentityMatchingInsertDeleteReorder() {
        // Insert X before C.
        let insert = PageRemap(old: ["A", "B", "C"], new: ["A", "B", "X", "C"])
        XCTAssertEqual(insert.mapping, [0, 1, 3])
        XCTAssertEqual(insert.map(p(2)), p(3))
        XCTAssertEqual(insert.map(p(1)), p(1))
        // Reorder.
        let move = PageRemap(old: ["A", "B", "C", "D"], new: ["C", "A", "B", "D"])
        XCTAssertEqual(move.mapping, [1, 2, 0, 3])
        XCTAssertEqual(move.map(p(2)), p(0))
        XCTAssertFalse(move.isIdentity)
        XCTAssertTrue(PageRemap(old: [1, 2], new: [1, 2]).isIdentity)
    }

    func testDeletedPageFallsToNextThenPrevious() {
        let delete = PageRemap(old: ["A", "B", "C", "D"], new: ["A", "D"])
        XCTAssertEqual(delete.map(p(1)), DocumentPosition(page: 1, x: 0.1, y: 0))   // B -> D (next survivor)
        XCTAssertEqual(delete.map(p(3)), p(1))
        let tail = PageRemap(old: ["A", "B", "C"], new: ["A"])
        XCTAssertEqual(tail.map(p(2)), DocumentPosition(page: 0, x: 0.1, y: 0))     // no next: previous
        XCTAssertNil(PageRemap(old: ["A"], new: [String]()).map(p(0)))
        // Out-of-range positions are clamped.
        XCTAssertEqual(tail.map(p(7)), p(0))
    }

    func testByIndex() {
        let reload = PageRemap.byIndex(oldCount: 5, newCount: 3)
        XCTAssertEqual(reload.map(p(1)), p(1))
        XCTAssertEqual(reload.map(p(4)), DocumentPosition(page: 2, x: 0.1, y: 0))
    }

    func testMarksFollowPages() {
        var marks = Marks()
        marks.set("a", p(0)); marks.set("b", p(2)); marks.set("c", p(1))
        marks.remap(PageRemap(old: ["A", "B", "C"], new: ["C", "A"]))  // B deleted, C moved first
        XCTAssertEqual(marks.get("a"), p(1))
        XCTAssertEqual(marks.get("b"), p(0))
        XCTAssertEqual(marks.get("c"), DocumentPosition(page: 0, x: 0.1, y: 0))  // B gone: next survivor C, now first
        marks.remap(PageRemap(old: ["C", "A"], new: [String]()))
        XCTAssertTrue(marks.all.isEmpty)
    }

    func testJumpListFollowsPagesAndMerges() {
        var j = JumpList()
        j.record(p(0)); j.record(p(1)); j.record(p(2)); j.record(p(3))
        // Delete page 2 (C): its entry moves to D, merging with D's entry.
        j.remap(PageRemap(old: ["A", "B", "C", "D"], new: ["A", "B", "D"]))
        XCTAssertEqual(j.positions.map(\.page), [0, 1, 2])
        XCTAssertEqual(j.back(from: p(2)), p(1))
        XCTAssertEqual(j.back(from: p(1)), p(0))
        XCTAssertNil(j.back(from: p(0)))
        // Cursor is mid-list now (on entry 0); a reorder keeps it on that entry.
        j.remap(PageRemap(old: ["A", "B", "D"], new: ["D", "B", "A"]))
        XCTAssertEqual(j.positions.map(\.page), [2, 1, 0])
        XCTAssertEqual(j.forward()?.page, 1)
        XCTAssertEqual(j.forward()?.page, 0)
        XCTAssertNil(j.forward())
    }

    func testJumpListCursorOnRemovedEntryMovesToNextSurvivor() {
        var j = JumpList()
        j.record(p(0)); j.record(p(1)); j.record(p(2))
        XCTAssertEqual(j.back(from: p(3)), p(2))
        XCTAssertEqual(j.back(from: p(2)), p(1))     // cursor on page 1's entry
        // Every page goes away but one: entries collapse onto it.
        j.remap(PageRemap(old: ["A", "B", "C", "D"], new: ["D"]))
        XCTAssertEqual(j.positions.map(\.page), [0])
        XCTAssertNil(j.forward())
    }
}
