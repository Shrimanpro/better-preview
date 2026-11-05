import AppKit
import PDFKit

/// PDFView with hooks the controller needs: key interception and resize
/// notification.
///
/// On macOS 27 the PDFView itself is the first responder; its inner
/// `PDFDocumentView` and page views refuse first responder status, so
/// overriding `keyDown` here sees every key that reaches the document.
@MainActor
final class BPPDFView: PDFView {
    /// Called before PDFView's own key handling. Return true to consume.
    var keyHandler: ((NSEvent) -> Bool)?
    /// Called after the view's size changed (window resize, sidebar, ...).
    var onResize: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// Mouse events offered to editing features first. Return true to consume.
    var mouseHandler: ((NSEvent) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        if mouseHandler?(event) != true { super.mouseDown(with: event) }
    }

    override func mouseDragged(with event: NSEvent) {
        if mouseHandler?(event) != true { super.mouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if mouseHandler?(event) != true { super.mouseUp(with: event) }
    }

    override func mouseMoved(with event: NSEvent) {
        if mouseHandler?(event) != true { super.mouseMoved(with: event) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?() }
    }

    /// PDFView's internal scroll view, found by walking the public view
    /// hierarchy breadth-first. Nil if a future PDFKit stops using one.
    var enclosedScrollView: NSScrollView? {
        var queue = subviews[...]
        while let view = queue.popFirst() {
            if let scrollView = view as? NSScrollView { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}
