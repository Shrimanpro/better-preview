import AppKit
import BPCore
import PDFKit

/// AcroForm filling (PDFKit's own widget editing, plus insert-mode and dirty
/// tracking) and signature stamps. Signature code is in
/// `FormsFeature+Signatures.swift`, form tracking in `FormsFeature+Fields.swift`.
@MainActor
final class FormsFeature: PDFFeature {
    unowned let controller: PDFDocumentController

    // Form tracking.
    struct WidgetValue: Equatable {
        var string: String?
        var state: Int
    }
    struct TrackedPage {
        var page: PDFPage
        var items: [(annotation: PDFAnnotation, value: WidgetValue)]
    }
    var tracked: [ObjectIdentifier: TrackedPage] = [:]
    var modeSyncScheduled = false

    // Signatures.
    enum Drag {
        case move(startPoint: CGPoint, startBounds: CGRect)
        case resize(corner: Int, startBounds: CGRect)
    }
    var placed: [SignatureAnnotation] = []
    var selected: SignatureAnnotation?
    var drag: Drag?
    var dragOriginalBounds: CGRect?
    var lastUsedSignature: String?
    /// Pages already searched for signatures saved by an earlier session.
    let adoptedPages = NSHashTable<PDFPage>.weakObjects()

    init(controller: PDFDocumentController) {
        self.controller = controller
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textEditingChanged(_:)),
                           name: NSText.didBeginEditingNotification, object: nil)
        center.addObserver(self, selector: #selector(textEditingChanged(_:)),
                           name: NSText.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(textEditingChanged(_:)),
                           name: NSText.didEndEditingNotification, object: nil)
        FormsSelfTest.runIfRequested(from: self)
    }

    var pdfView: BPPDFView { controller.pdfView }

    func handle(_ invocation: ActionInvocation) -> Bool {
        switch invocation.action.name {
        case .signatureManage:
            SignatureManager.shared.show(for: self)
            return true
        case .signaturePlace:
            placeSignature(named: invocation.action.argument)
            return true
        case .annotationDelete:
            guard let selected else { return false }
            removeSignature(selected)
            return true
        case .abort:
            // Esc deselects a signature; shared with other features, so
            // never consumed.
            if selected != nil { select(nil) }
            return false
        default:
            return false
        }
    }

    var statusFlags: [String] { selected == nil ? [] : ["signature"] }

    func documentDidReload() {
        placed.removeAll()
        adoptedPages.removeAllObjects()
        selected = nil
        drag = nil
        tracked.removeAll()
    }

    /// Before a save, close or quit: form values PDFKit committed when the
    /// field lost focus (or a popup changed without a mouse-up reaching us)
    /// are compared now, so they mark the document dirty and get undo.
    func commitPendingEdits() {
        checkChanges()
    }

    func tearDown() {
        NotificationCenter.default.removeObserver(self)
        select(nil)
        drag = nil
    }

    func handleMouse(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown:
            baselineVisiblePages()
            return signatureMouseDown(event)
        case .leftMouseDragged:
            return drag != nil && signatureMouseDragged(event)
        case .leftMouseUp:
            scheduleSync()
            return drag != nil && signatureMouseUp(event)
        default:
            return false
        }
    }
}
