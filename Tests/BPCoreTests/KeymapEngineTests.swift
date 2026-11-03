import XCTest
@testable import BPCore

final class KeymapEngineTests: XCTestCase {
    private func engine(_ maps: [(String, ActionName)], mode: Mode = .normal) -> KeymapEngine {
        KeymapEngine(bindings: maps.map { KeyBinding(mode: mode, keys: $0.0, action: Action($0.1)) })
    }

    /// Feeds `keys` (vim notation) and returns all results in order.
    private func feed(_ e: KeymapEngine, _ keys: String, mode: Mode = .normal) -> [KeyResult] {
        try! KeyNotation.parse(keys).flatMap { Array(e.feed($0, mode: mode)) }
    }

    private func inv(_ name: ActionName, _ arg: String? = nil, count: Int? = nil) -> KeyResult {
        .invoke(ActionInvocation(name, arg, count: count))
    }

    // MARK: Sequences

    func testSingleKey() {
        let e = engine([("j", .scrollDown)])
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertFalse(e.needsTimeout)
    }

    func testUnambiguousSequence() {
        let e = engine([("gg", .gotoFirst), ("j", .scrollDown)])
        XCTAssertEqual(feed(e, "g"), [.pending])
        XCTAssertFalse(e.needsTimeout)
        XCTAssertEqual(e.pendingDisplay, "g")
        XCTAssertEqual(feed(e, "g"), [inv(.gotoFirst)])
        XCTAssertEqual(e.pendingDisplay, "")
    }

    func testDeadEndDropsStroke() {
        let e = engine([("gg", .gotoFirst), ("x", .annotationDelete)])
        XCTAssertEqual(feed(e, "gx"), [.pending, .cancelled])
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertEqual(feed(e, "x"), [inv(.annotationDelete)])
    }

    func testAmbiguousContinued() {
        let e = engine([("g", .gotoLast), ("gg", .gotoFirst)])
        XCTAssertEqual(feed(e, "g"), [.pending])
        XCTAssertTrue(e.needsTimeout)
        XCTAssertEqual(feed(e, "g"), [inv(.gotoFirst)])
        XCTAssertFalse(e.needsTimeout)
    }

    func testAmbiguousTimeout() {
        let e = engine([("g", .gotoLast), ("gg", .gotoFirst)])
        _ = feed(e, "3g")
        XCTAssertEqual(e.pendingDisplay, "3g")
        XCTAssertEqual(e.timeout(), inv(.gotoLast, count: 3))
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertFalse(e.needsTimeout)
    }

    func testAmbiguousInterruptedFiresShorterThenProcessesStroke() {
        let e = engine([("g", .gotoLast), ("gg", .gotoFirst), ("j", .scrollDown), ("zi", .zoomIn)])
        XCTAssertEqual(feed(e, "2gj"), [.pending, .pending, inv(.gotoLast, count: 2), inv(.scrollDown)])
        // The interrupting stroke may itself start a sequence.
        XCTAssertEqual(feed(e, "gz"), [.pending, inv(.gotoLast), .pending])
        XCTAssertEqual(e.pendingDisplay, "z")
        XCTAssertEqual(feed(e, "i"), [inv(.zoomIn)])
        // Or be unbound.
        XCTAssertEqual(feed(e, "gq"), [.pending, inv(.gotoLast), .unhandled])
        // Or be a count digit.
        XCTAssertEqual(feed(e, "g5"), [.pending, inv(.gotoLast), .pending])
        XCTAssertEqual(e.pendingDisplay, "5")
    }

    func testAmbiguousDeeper() {
        let e = engine([("ab", .zoomIn), ("abc", .zoomOut), ("a", .fitPage)])
        XCTAssertEqual(feed(e, "a"), [.pending])
        XCTAssertTrue(e.needsTimeout)
        XCTAssertEqual(feed(e, "b"), [.pending])
        XCTAssertTrue(e.needsTimeout)
        XCTAssertEqual(feed(e, "c"), [inv(.zoomOut)])
    }

    func testIncompleteSequenceTimeoutCancels() {
        let e = engine([("gg", .gotoFirst)])
        _ = feed(e, "g")
        XCTAssertEqual(e.timeout(), .cancelled)
        XCTAssertEqual(e.pendingDisplay, "")
    }

    func testStaleTimeoutIsNoOp() {
        let e = engine([("m", .markSet)])
        XCTAssertEqual(e.timeout(), .unhandled)
        _ = feed(e, "12")
        XCTAssertEqual(e.timeout(), .unhandled)
        XCTAssertEqual(e.pendingDisplay, "12")
        _ = feed(e, "m")
        XCTAssertEqual(e.timeout(), .unhandled)
        XCTAssertEqual(feed(e, "a"), [inv(.markSet, "a", count: 12)])
    }

    func testLaterBindingOverrides() {
        let e = KeymapEngine(bindings: [
            KeyBinding(keys: "<C-d>", action: Action(.scrollHalfDown)),
            KeyBinding(keys: "<c-d>", action: Action(.quit)),
        ])
        XCTAssertEqual(feed(e, "<C-d>"), [inv(.quit)])
    }

    func testInvalidBindingsSkipped() {
        let e = KeymapEngine(bindings: [
            KeyBinding(keys: "<Nope>", action: Action(.quit)),
            KeyBinding(keys: "", action: Action(.quit)),
            KeyBinding(keys: "j", action: Action(.scrollDown)),
        ])
        XCTAssertEqual(e.invalidBindings.map(\.0.keys), ["<Nope>", ""])
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
    }

    func testBindingArgumentPassesThrough() {
        let e = KeymapEngine(bindings: [KeyBinding(keys: "o", action: Action(.enterCommand, "open "))])
        XCTAssertEqual(feed(e, "o"), [inv(.enterCommand, "open ")])
    }

    // MARK: Counts

    func testCount() {
        let e = engine([("j", .scrollDown), ("gg", .gotoFirst)])
        XCTAssertEqual(feed(e, "1"), [.pending])
        XCTAssertEqual(feed(e, "0"), [.pending])
        XCTAssertEqual(e.pendingDisplay, "10")
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown, count: 10)])
        XCTAssertEqual(feed(e, "5gg"), [.pending, .pending, inv(.gotoFirst, count: 5)])
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
    }

    func testZeroWithoutCountIsAKey() {
        let e = engine([("0", .zoomReset)])
        XCTAssertEqual(feed(e, "0"), [inv(.zoomReset)])
        XCTAssertEqual(engine([]).feed(KeyStroke("0"), mode: .normal), KeyResults(.unhandled))
    }

    func testDigitsInsideSequence() {
        let e = engine([("z0", .zoomReset)])
        XCTAssertEqual(feed(e, "z0"), [.pending, inv(.zoomReset)])
        XCTAssertEqual(feed(e, "4z0"), [.pending, .pending, inv(.zoomReset, count: 4)])
        XCTAssertEqual(feed(e, "z1"), [.pending, .cancelled])
    }

    func testCountCap() {
        let e = engine([("j", .scrollDown)])
        XCTAssertEqual(feed(e, "99999999j").last, inv(.scrollDown, count: 999_999))
    }

    func testCountThenUnboundCancels() {
        let e = engine([("j", .scrollDown)])
        XCTAssertEqual(feed(e, "3q"), [.pending, .cancelled])
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
    }

    func testCountsInPresentationMode() {
        let e = engine([("j", .pageNext)], mode: .presentation)
        XCTAssertEqual(feed(e, "2j", mode: .presentation), [.pending, inv(.pageNext, count: 2)])
    }

    // MARK: Awaiting a character

    func testMarkSetAwaitsCharacter() {
        let e = engine([("m", .markSet), ("'", .markJump)])
        XCTAssertEqual(feed(e, "m"), [.pending])
        XCTAssertEqual(e.pendingDisplay, "m")
        XCTAssertFalse(e.needsTimeout)
        XCTAssertEqual(feed(e, "a"), [inv(.markSet, "a")])
        XCTAssertEqual(feed(e, "'A"), [.pending, inv(.markJump, "A")])
        XCTAssertEqual(feed(e, "''"), [.pending, inv(.markJump, "'")])
        XCTAssertEqual(feed(e, "m1"), [.pending, inv(.markSet, "1")])
    }

    func testAwaitedCharacterIgnoresBindingArgument() {
        let e = KeymapEngine(bindings: [KeyBinding(keys: "m", action: Action(.markSet, "zzz"))])
        XCTAssertEqual(feed(e, "mb"), [.pending, inv(.markSet, "b")])
    }

    func testAwaitCancelledByEscOrNonPrintable() {
        let e = engine([("m", .markSet)])
        XCTAssertEqual(feed(e, "m<Esc>"), [.pending, .cancelled])
        XCTAssertEqual(feed(e, "m<Space>"), [.pending, .cancelled])
        XCTAssertEqual(feed(e, "m<C-a>"), [.pending, .cancelled])
        XCTAssertEqual(feed(e, "m<A-a>"), [.pending, .cancelled])
        XCTAssertEqual(feed(e, "m<Down>"), [.pending, .cancelled])
        XCTAssertEqual(e.pendingDisplay, "")
    }

    func testAwaitingSequenceBinding() {
        let e = engine([("gm", .markSet)])
        XCTAssertEqual(feed(e, "gmx"), [.pending, .pending, inv(.markSet, "x")])
    }

    func testAmbiguousAwaitingActionTakesInterruptingStrokeAsCharacter() {
        let e = engine([("m", .markSet), ("mm", .toggleSidebar)])
        XCTAssertEqual(feed(e, "m"), [.pending])
        XCTAssertTrue(e.needsTimeout)
        XCTAssertEqual(feed(e, "a"), [inv(.markSet, "a")])
        XCTAssertEqual(feed(e, "mm"), [.pending, inv(.toggleSidebar)])
        _ = feed(e, "m")
        XCTAssertEqual(e.timeout(), .pending)
        XCTAssertFalse(e.needsTimeout)
        XCTAssertEqual(feed(e, "m"), [inv(.markSet, "m")])
    }

    // MARK: Esc

    func testEscWithNothingPendingIsLookedUp() {
        let e = engine([("<Esc>", .abort)])
        XCTAssertEqual(feed(e, "<Esc>"), [inv(.abort)])
    }

    func testEscCancelsPendingWithoutInvoking() {
        let e = engine([("<Esc>", .abort), ("g", .gotoLast), ("gg", .gotoFirst), ("zi", .zoomIn)])
        XCTAssertEqual(feed(e, "12<Esc>"), [.pending, .pending, .cancelled])
        XCTAssertEqual(feed(e, "z<Esc>"), [.pending, .cancelled])
        XCTAssertEqual(feed(e, "g<Esc>"), [.pending, .cancelled])
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertFalse(e.needsTimeout)
        XCTAssertEqual(feed(e, "<Esc>"), [inv(.abort)])
    }

    // MARK: Cmd shortcuts

    func testUnboundCmdIsNeverSwallowed() {
        let e = engine([("gg", .gotoFirst), ("g", .gotoLast), ("zi", .zoomIn), ("m", .markSet)])
        XCTAssertEqual(feed(e, "<D-s>"), [.unhandled])
        XCTAssertEqual(feed(e, "3<D-s>"), [.pending, .unhandled])
        XCTAssertEqual(feed(e, "z<D-s>"), [.pending, .unhandled])
        XCTAssertEqual(feed(e, "g<D-s>"), [.pending, inv(.gotoLast), .unhandled])
        XCTAssertEqual(feed(e, "m<D-s>"), [.pending, .unhandled])
        XCTAssertEqual(e.pendingDisplay, "")
    }

    func testBoundCmd() {
        let e = engine([("<D-j>", .pageNext), ("zi", .zoomIn)])
        XCTAssertEqual(feed(e, "2<D-j>"), [.pending, inv(.pageNext, count: 2)])
        XCTAssertEqual(feed(e, "z<D-j>"), [.pending, inv(.pageNext)])
    }

    // MARK: Modes

    func testModesHaveSeparateBindings() {
        let e = KeymapEngine(bindings: [
            KeyBinding(keys: "j", action: Action(.scrollDown)),
            KeyBinding(mode: .presentation, keys: "j", action: Action(.pageNext)),
        ])
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
        XCTAssertEqual(feed(e, "j", mode: .presentation), [inv(.pageNext)])
        XCTAssertEqual(feed(e, "j", mode: .insert), [.unhandled])
    }

    func testInsertAndCommandModesHaveNoCounts() {
        for mode in [Mode.insert, .command] {
            let e = engine([("<Esc>", .abort), ("1", .zoomIn)], mode: mode)
            XCTAssertEqual(feed(e, "1", mode: mode), [inv(.zoomIn)])
            XCTAssertEqual(feed(e, "2", mode: mode), [.unhandled])
            XCTAssertEqual(feed(e, "x", mode: mode), [.unhandled])
            XCTAssertEqual(feed(e, "<Esc>", mode: mode), [inv(.abort)])
            XCTAssertEqual(e.pendingDisplay, "")
        }
    }

    func testModeChangeResetsPending() {
        let e = engine([("gg", .gotoFirst), ("j", .scrollDown)])
        _ = feed(e, "3g")
        XCTAssertEqual(feed(e, "g", mode: .insert), [.unhandled])
        XCTAssertEqual(feed(e, "j"), [inv(.scrollDown)])
        _ = feed(e, "5")
        XCTAssertEqual(feed(e, "j", mode: .presentation), [.unhandled])
    }

    func testReset() {
        let e = engine([("gg", .gotoFirst)])
        _ = feed(e, "4g")
        e.reset()
        XCTAssertEqual(e.pendingDisplay, "")
        XCTAssertEqual(feed(e, "g"), [.pending])
    }

    // MARK: Defaults
}
