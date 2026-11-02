import XCTest
@testable import BPCore

final class InterfacesTests: XCTestCase {
    func testHexParsing() {
        XCTAssertEqual(RGBA(hex: "#fff"), RGBA(r: 1, g: 1, b: 1))
        XCTAssertEqual(RGBA(hex: "000000"), RGBA(r: 0, g: 0, b: 0))
        XCTAssertEqual(RGBA(hex: "#ff000080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGBA(hex: "#12"))
        XCTAssertNil(RGBA(hex: "#gggggg"))
    }

    func testActionNamesAreUnique() {
        let names = ActionName.allCases.map(\.rawValue)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testThemeColorKeys() {
        XCTAssertNotNil(Theme.colorKeys["recolor-darkcolor"])
    }
}
