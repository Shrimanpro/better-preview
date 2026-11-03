public enum KeyResult: Equatable, Sendable {
    /// Stroke consumed, waiting for more (count digits, a partial sequence, or
    /// an `awaitsCharacter` action waiting for its character).
    case pending
    /// Fire this.
    case invoke(ActionInvocation)
    /// Stroke consumed and pending input discarded (Esc while something was
    /// pending, a sequence that ran into a dead end, a count before an
    /// unbound key).
    case cancelled
    /// Nothing bound: let the event continue through the responder chain.
    case unhandled
}

/// What one stroke produced: one result, or two when an ambiguous pending
/// binding (`g`, with `gg` also bound) is ended by a stroke that does not
/// continue it. Then `primary` invokes the shorter binding and `followUp` is the
/// stroke processed afresh as the start of new input. Stored inline, so
/// feeding a stroke does not allocate.
public struct KeyResults: RandomAccessCollection, Equatable, Sendable {
    public let primary: KeyResult
    public let followUp: KeyResult?

    init(_ primary: KeyResult, _ followUp: KeyResult? = nil) {
        self.primary = primary
        self.followUp = followUp
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { followUp == nil ? 1 : 2 }
    public subscript(i: Int) -> KeyResult {
        precondition(i >= 0 && i < endIndex, "KeyResults index out of range")
        return i == 0 ? primary : followUp!
    }
}
