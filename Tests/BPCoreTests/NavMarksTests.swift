import XCTest
@testable import BPCore

final class NavMarksTests: XCTestCase {
    func testValidNames() {
        for c in "azAZ09" { XCTAssertTrue(Marks.isValidName(c), "\(c)") }
        for c in "-_ é'`" { XCTAssertFalse(Marks.isValidName(c), "\(c)") }
    }

    func testSetGetOverwrite() {
        var m = Marks()
        XCTAssertTrue(m.set("a", DocumentPosition(page: 1)))
        XCTAssertEqual(m.get("a")?.page, 1)
        m.set("a", DocumentPosition(page: 2))
        XCTAssertEqual(m.get("a")?.page, 2)
        XCTAssertNil(m.get("b"))
    }

    func testInvalidIgnored() {
        var m = Marks()
        XCTAssertFalse(m.set("!", DocumentPosition(page: 1)))
        XCTAssertTrue(m.all.isEmpty)
    }

    func testAllSorted() {
        var m = Marks()
        for c in "bAa1" { m.set(c, DocumentPosition(page: 0)) }
        XCTAssertEqual(m.all.map { String($0.0) }, ["1", "A", "a", "b"])
    }

    func testRemoveAll() {
        var m = Marks()
        m.set("a", DocumentPosition(page: 0))
        m.removeAll()
        XCTAssertNil(m.get("a"))
    }

    func testClamp() {
        var m = Marks()
        m.set("a", DocumentPosition(page: 2, x: 0.5, y: 0.5, zoom: 2))
        m.set("b", DocumentPosition(page: 9, x: 0.5, y: 0.5, zoom: 2))
        m.clamp(pageCount: 5)
        XCTAssertEqual(m.get("a"), DocumentPosition(page: 2, x: 0.5, y: 0.5, zoom: 2))
        XCTAssertEqual(m.get("b"), DocumentPosition(page: 4, zoom: 2))
        m.clamp(pageCount: 0)
        XCTAssertTrue(m.all.isEmpty)
    }
}
