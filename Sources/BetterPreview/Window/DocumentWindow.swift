import AppKit

/// A document window that offers every key-down to `keyRouter` before normal
/// event handling, so vim keys work wherever focus is in the window.
///
/// Cmd-modified keys are offered in `performKeyEquivalent` (which AppKit calls
/// before the main menu); all other keys in `sendEvent`. Each event is
/// offered at most once. Sheets and other windows have their own event
/// handling and never pass through here.
@MainActor
final class DocumentWindow: NSWindow {
    /// Returns true when it consumed the event.
    var keyRouter: ((NSEvent) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, !event.modifierFlags.contains(.command), keyRouter?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), keyRouter?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}
