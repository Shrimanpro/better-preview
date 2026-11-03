/// Resolves key strokes to actions: per-mode key tries, vim counts,
/// ambiguous sequences with a timeout, and actions that await a character.
///
/// Driving it (on the main thread):
/// 1. For every key-down, `for r in engine.feed(stroke, mode: mode)`: run
///    `.invoke`s in order; if any result is `.unhandled`, pass the event on.
/// 2. After each `feed`, invalidate any running key timer, then start one of
///    `Options.keyTimeout` ms if `needsTimeout` is true. When it fires, handle
///    `timeout()` the same way.
/// 3. Show `pendingDisplay` in the status bar after each `feed`/`timeout`.
public final class KeymapEngine {
    private final class Node {
        var children: [KeyStroke: Node] = [:]
        var action: Action?
    }

    private static let maxCount = 999_999

    private var roots: [Mode: Node] = [:]
    public private(set) var invalidBindings: [(KeyBinding, String)] = []

    // Pending state. Empty when `node == nil && count == nil && awaiting == nil`.
    private var pendingMode: Mode?
    /// Position inside a partially typed sequence.
    private var node: Node?
    /// Strokes of the pending sequence, for `pendingDisplay`.
    private var sequence: [KeyStroke] = []
    private var count: Int?
    /// A resolved action waiting for its character argument.
    private var awaiting: Action?

    /// Bindings are applied in order; a later binding for the same mode and
    /// keys replaces an earlier one. Bindings whose keys do not parse are
    /// skipped and listed in `invalidBindings` with the reason.
    public init(bindings: [KeyBinding]) {
        for binding in bindings {
            do {
                let strokes = try KeyNotation.parse(binding.keys)
                var node = root(binding.mode)
                for s in strokes {
                    if let next = node.children[s] {
                        node = next
                    } else {
                        let next = Node()
                        node.children[s] = next
                        node = next
                    }
                }
                node.action = binding.action
            } catch {
                invalidBindings.append((binding, "\(error)"))
            }
        }
    }

    private func root(_ mode: Mode) -> Node {
        if let r = roots[mode] { return r }
        let r = Node()
        roots[mode] = r
        return r
    }

    private var hasPending: Bool { node != nil || count != nil || awaiting != nil }

    /// True when the pending sequence is itself a complete binding that a
    /// longer one extends (`g` with `gg` bound): the caller must start the
    /// key timer.
    public var needsTimeout: Bool { node?.action != nil }

    /// Pending input for the status bar: `"12"`, `"12g"`, `"m"`, or `""`.
    public var pendingDisplay: String {
        guard hasPending else { return "" }
        return (count.map(String.init) ?? "") + KeyNotation.format(sequence)
    }

    public func reset() {
        node = nil
        sequence.removeAll(keepingCapacity: true)
        count = nil
        awaiting = nil
    }

    /// Feeds one key-down. Switching `mode` between calls discards pending
    /// input. See `KeyResults` for when two results come back.
    public func feed(_ stroke: KeyStroke, mode: Mode) -> KeyResults {
        if pendingMode != mode {
            reset()
            pendingMode = mode
        }
        return step(stroke, mode)
    }

    /// Called when the key timer fires. Invokes the pending sequence if it is
    /// a complete binding (`.pending` again if that action awaits a character),
    /// cancels an incomplete sequence, and returns `.unhandled` (doing
    /// nothing) when no sequence is pending: counts and awaited characters
    /// do not time out.
    public func timeout() -> KeyResult {
        guard let node else { return .unhandled }
        guard let action = node.action else {
            reset()
            return .cancelled
        }
        return resolve(action)
    }

    private func step(_ stroke: KeyStroke, _ mode: Mode) -> KeyResults {
        let isCmd = stroke.modifiers.contains(.cmd)

        if let action = awaiting {
            // Cmd shortcuts are never swallowed: drop the wait and start fresh.
            if isCmd {
                reset()
                return step(stroke, mode)
            }
            let c = count
            reset()
            guard let ch = stroke.character, stroke.modifiers.isDisjoint(with: [.ctrl, .alt]) else {
                return KeyResults(.cancelled)
            }
            return KeyResults(.invoke(ActionInvocation(action.name, String(ch), count: c)))
        }

        if let node {
            if let next = node.children[stroke] { return KeyResults(advance(next, stroke)) }
            if stroke == .escape {
                reset()
                return KeyResults(.cancelled)
            }
            if let action = node.action {
                // Ambiguous prefix not continued: fire it, then start over with this stroke.
                let fired = resolve(action)
                let rest = step(stroke, mode)
                // An awaiting action consumes `stroke` as its character.
                return fired == .pending ? rest : KeyResults(fired, rest.primary)
            }
            // Dead end: vim drops the stroke, but cmd shortcuts get a fresh lookup.
            reset()
            return isCmd ? step(stroke, mode) : KeyResults(.cancelled)
        }

        if stroke == .escape && count != nil {
            reset()
            return KeyResults(.cancelled)
        }
        if mode == .normal || mode == .presentation, let d = stroke.digit, d != 0 || count != nil {
            count = min((count ?? 0) * 10 + d, Self.maxCount)
            return KeyResults(.pending)
        }
        guard let next = roots[mode]?.children[stroke] else {
            let hadCount = count != nil
            reset()
            return KeyResults(hadCount && !isCmd ? .cancelled : .unhandled)
        }
        return KeyResults(advance(next, stroke))
    }

    private func advance(_ next: Node, _ stroke: KeyStroke) -> KeyResult {
        if next.children.isEmpty, let action = next.action {
            if action.name.awaitsCharacter { sequence.append(stroke) }
            return resolve(action)
        }
        node = next
        sequence.append(stroke)
        return .pending
    }

    /// Completes `action` with the pending count. Character-awaiting actions
    /// become pending instead.
    private func resolve(_ action: Action) -> KeyResult {
        if action.name.awaitsCharacter {
            node = nil
            awaiting = action
            return .pending
        }
        let c = count
        reset()
        return .invoke(ActionInvocation(action, count: c))
    }
}
