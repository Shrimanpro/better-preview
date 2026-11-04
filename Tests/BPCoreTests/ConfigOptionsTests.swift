import XCTest
@testable import BPCore

final class ConfigOptionsTests: XCTestCase {
    /// A non-default value for every rc key.
    private let nonDefault: [String: String] = [
        "scroll-step": "33", "scroll-hstep": "44", "smooth-scroll": "no", "scroll-duration": "0.5",
        "scroll-page-overlap": "0.25", "zoom-step": "1.25", "zoom-min": "0.2", "zoom-max": "7",
        "default-fit": "page", "continuous": "off", "dual-page": "yes", "dual-page-book": "0",
        "page-padding": "3", "recolor": "on", "recolor-keephue": "1", "trim-margins": "true",
        "trim-padding": "9", "theme": "nord", "theme-light": "dracula", "theme-dark": "gruvbox-dark",
        "statusbar": "false", "toolbar": "true", "sidebar": "true", "sidebar-width": "240",
        "font": "Menlo", "font-size": "14", "key-timeout": "250", "incremental-search": "false",
        "search-wrap": "false", "search-smartcase": "false", "auto-reload": "false", "synctex": "false",
        "synctex-editor-command": "nvim +%{line} %{input}", "ocr-languages": "en-US,de-DE",
        "pdfkit-analysis": "true",
    ]

    func testEveryOptionFieldIsReachable() throws {
        XCTAssertEqual(Set(nonDefault.keys), Set(Options.rcKeys))
        var o = Options()
        for key in Options.rcKeys { try o.set(key, to: nonDefault[key]!) }
        let changed = Mirror(reflecting: o).children
        let original = Mirror(reflecting: Options()).children
        XCTAssertEqual(changed.count, Options.rcKeys.count)
        for (new, old) in zip(changed, original) {
            XCTAssertNotEqual("\(new.value)", "\(old.value)", "field \(new.label ?? "?") not reachable via rc")
        }
    }

    func testValueRoundTrip() throws {
        var o = Options()
        for key in Options.rcKeys { try o.set(key, to: nonDefault[key]!) }
        var copy = Options()
        for key in Options.rcKeys { try copy.set(key, to: o.value(forKey: key)!) }
        XCTAssertEqual(copy, o)
        XCTAssertEqual(Options().value(forKey: "scroll-step"), "80")
        XCTAssertEqual(Options().value(forKey: "zoom-step"), "1.1")
        XCTAssertEqual(Options().value(forKey: "continuous"), "true")
        XCTAssertNil(Options().value(forKey: "nope"))
    }

    func testPDFKitAnalysisOption() throws {
        XCTAssertFalse(Options().pdfkitAnalysis)
        let defaults = ConfigLoader.load(readFile: { _ in nil })
        XCTAssertTrue(defaults.diagnostics.isEmpty)
        XCTAssertFalse(defaults.options.pdfkitAnalysis)
        XCTAssertEqual(defaults.options.value(forKey: "pdfkit-analysis"), "false")
        let user = ConfigLoader.load(userRCPath: "/u/rc", readFile: { $0 == "/u/rc" ? "set pdfkit-analysis true\n" : nil })
        XCTAssertTrue(user.options.pdfkitAnalysis)
        var o = Options()
        XCTAssertThrowsError(try o.set("pdfkit-analysis", to: "maybe"))
        try o.set("pdfkit-analysis", to: "on")
        XCTAssertTrue(o.pdfkitAnalysis)
    }

    func testBoolSpellings() throws {
        var o = Options()
        for t in ["true", "TRUE", "yes", "on", "1"] {
            o.recolor = false
            try o.set("recolor", to: t)
            XCTAssertTrue(o.recolor, t)
        }
        for f in ["false", "No", "off", "0"] {
            o.recolor = true
            try o.set("recolor", to: f)
            XCTAssertFalse(o.recolor, f)
        }
        XCTAssertThrowsError(try o.set("recolor", to: "maybe"))
    }

    func testNumberValidation() {
        var o = Options()
        for bad in ["nan", "inf", "-1", "abc", ""] {
            XCTAssertThrowsError(try o.set("scroll-step", to: bad), bad)
        }
        XCTAssertThrowsError(try o.set("key-timeout", to: "1.5"))
        XCTAssertThrowsError(try o.set("key-timeout", to: "-5"))
        XCTAssertThrowsError(try o.set("scroll-page-overlap", to: "2"))
        XCTAssertThrowsError(try o.set("default-fit", to: "huge"))
        XCTAssertEqual(o, Options())
    }

    func testErrorMessageNamesKeyAndValue() {
        var o = Options()
        XCTAssertThrowsError(try o.set("scroll-step", to: "fast")) { error in
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("scroll-step") && text.contains("fast"), text)
            XCTAssertTrue(error is ConfigError)
        }
        XCTAssertThrowsError(try o.set("bogus", to: "1")) {
            XCTAssertTrue($0.localizedDescription.contains("bogus"))
        }
    }
}
