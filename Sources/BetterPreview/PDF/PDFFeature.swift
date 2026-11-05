import AppKit
import BPCore
import PDFKit

/// A PDF editing feature (markup, page management, forms) that plugs into
/// `PDFDocumentController` from its own directory. Created lazily on first
/// use; keep `init` trivial and build UI only when needed.
@MainActor
protocol PDFFeature: AnyObject {
    /// Returns true when the feature handled the action.
    func handle(_ invocation: ActionInvocation) -> Bool
    /// Extra status-bar flags, e.g. the active tool.
    var statusFlags: [String] { get }
    /// Mouse events (down, dragged, up, moved) offered before PDFView sees
    /// them. Return true to consume. Must be cheap when the feature is idle.
    func handleMouse(_ event: NSEvent) -> Bool
    /// The document object was replaced (reload from disk).
    func documentDidReload()
    /// The document is about to be written, or its dirty state is about to
    /// be read for closing or quitting: finish and record edits in progress
    /// (an open text editor, form values not compared yet).
    func commitPendingEdits()
    /// The window is closing: remove observers, monitors and timers.
    func tearDown()
}

extension PDFFeature {
    var statusFlags: [String] { [] }
    func handleMouse(_ event: NSEvent) -> Bool { false }
    func documentDidReload() {}
    func commitPendingEdits() {}
    func tearDown() {}
}

extension PDFDocumentController {
    /// See `PDFFeature.commitPendingEdits`.
    func commitPendingEdits() {
        for feature in features { feature.commitPendingEdits() }
    }

    /// See `PDFFeature.tearDown`.
    func tearDownFeatures() {
        for feature in features { feature.tearDown() }
    }

}
