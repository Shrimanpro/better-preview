import XCTest
@testable import BPCore

final class NavJumpListTests: XCTestCase {
    private func p(_ n: Int) -> DocumentPosition { DocumentPosition(page: n) }

    func testEmpty() {
        var j = JumpList()
        XCTAssertNil(j.back(from: p(0)))
        XCTAssertNil(j.forward())
    }

    func testBackAndForwardPingPong() {
        var j = JumpList()
        j.record(p(1)); j.record(p(2)); j.record(p(3))   // now viewing 4
        XCTAssertEqual(j.back(from: p(4)), p(3))
        XCTAssertEqual(j.back(from: p(3)), p(2))
        XCTAssertEqual(j.back(from: p(2)), p(1))
        XCTAssertNil(j.back(from: p(1)))
        XCTAssertEqual(j.forward(), p(2))
        XCTAssertEqual(j.forward(), p(3))
        XCTAssertEqual(j.forward(), p(4))
        XCTAssertNil(j.forward())
        XCTAssertEqual(j.back(from: p(4)), p(3))
        XCTAssertEqual(j.forward(), p(4))
    }

    func testBackSavesCurrentPosition() {
        var j = JumpList()
        j.record(DocumentPosition(page: 1))
        let cur = DocumentPosition(page: 5, x: 0.2, y: 0.7)
        XCTAssertEqual(j.back(from: cur), p(1))
        XCTAssertEqual(j.forward(), cur)
    }

    func testRecordDeduplicatesSamePage() {
        var j = JumpList()
        j.record(DocumentPosition(page: 1, y: 0.1))
        j.record(DocumentPosition(page: 1, y: 0.9))
        XCTAssertEqual(j.back(from: p(7)), DocumentPosition(page: 1, y: 0.9))
        XCTAssertNil(j.back(from: p(1)))
    }

    func testBackFromSamePageAsNewestHasNothingOlder() {
        var j = JumpList()
        j.record(p(3))
        XCTAssertNil(j.back(from: DocumentPosition(page: 3, y: 0.5)))
        // State unchanged: still can go back from elsewhere.
        XCTAssertEqual(j.back(from: p(8)), p(3))
    }

    func testRecordAfterBackTruncatesForward() {
        var j = JumpList()
        j.record(p(1)); j.record(p(2)); j.record(p(3))
        XCTAssertEqual(j.back(from: p(4)), p(3))
        XCTAssertEqual(j.back(from: p(3)), p(2))
        j.record(p(2))                      // jump away from 2
        XCTAssertNil(j.forward())
        XCTAssertEqual(j.back(from: p(9)), p(2))
        XCTAssertEqual(j.back(from: p(2)), p(1))
        XCTAssertNil(j.back(from: p(1)))
    }

    func testRecordAfterBackFromDifferentPageKeepsOrder() {
        var j = JumpList()
        j.record(p(1)); j.record(p(2))
        XCTAssertEqual(j.back(from: p(3)), p(2))
        j.record(p(6))
        XCTAssertEqual(j.back(from: p(7)), p(6))
        XCTAssertEqual(j.back(from: p(6)), p(2))
        XCTAssertEqual(j.back(from: p(2)), p(1))
    }

    func testCapacityDropsOldest() {
        var j = JumpList(capacity: 3)
        for i in 1...5 { j.record(p(i)) }
        XCTAssertEqual(j.back(from: p(6)), p(5))
        XCTAssertEqual(j.back(from: p(5)), p(4))
        XCTAssertNil(j.back(from: p(4)))   // saving the tip pushed page 3 out
    }

    func testCapacityOneNeverGoesBack() {
        var j = JumpList(capacity: 1)
        j.record(p(1))
        XCTAssertNil(j.back(from: p(2)))
        XCTAssertNil(j.forward())
    }

    func testRemoveAll() {
        var j = JumpList()
        j.record(p(1))
        j.removeAll()
        XCTAssertNil(j.back(from: p(2)))
        XCTAssertNil(j.forward())
    }
}
