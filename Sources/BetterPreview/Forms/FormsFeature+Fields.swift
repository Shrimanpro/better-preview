import AppKit
import BPCore
import PDFKit

/// Form fields: PDFKit edits widgets itself; this tracks their values to set
/// `isDirty`, provide undo, and keeps the host's input mode in step with
/// field focus.
extension FormsFeature {
    // MARK: Focus and mode

    @objc func textEditingChanged(_ note: Notification) {
        guard let view = note.object as? NSView, view.isDescendant(of: pdfView) else { return }
        if note.name == NSText.didChangeNotification { controller.isDirty = true }
        scheduleSync()
    }

    /// Coalesced, runs after the current event so first-responder changes
    /// caused by it have happened.
    func scheduleSync() {
        guard !modeSyncScheduled else { return }
        modeSyncScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            modeSyncScheduled = false
            syncMode()
            checkChanges()
        }
    }

    private func syncMode() {
        guard let host = controller.host, host.mode == .normal || host.mode == .insert else { return }
        let editing = (pdfView.window?.firstResponder as? NSView).map {
            $0 is NSText && $0.isDescendant(of: pdfView)
        } ?? false
        if editing {
            if host.mode != .insert { host.setMode(.insert) }
        } else if host.mode == .insert {
            host.setMode(.normal)
        }
    }

    // MARK: Tracking

    func widgets(on page: PDFPage) -> [PDFAnnotation] {
        page.annotations.filter { $0.type == "Widget" }
    }

    func value(of annotation: PDFAnnotation) -> WidgetValue {
        WidgetValue(string: annotation.widgetStringValue, state: annotation.buttonWidgetState.rawValue)
    }

    func track(_ page: PDFPage) {
        let key = ObjectIdentifier(page)
        guard tracked[key] == nil else { return }
        tracked[key] = TrackedPage(page: page, items: widgets(on: page).map { ($0, value(of: $0)) })
    }

    /// Takes the "before" values of the pages on screen, ahead of an edit.
    func baselineVisiblePages() {
        for page in pdfView.visiblePages { track(page) }
    }

    /// Compares widgets to their baseline; a change marks the document dirty
    /// and registers one undo step.
    func checkChanges() {
        var changes: [(PDFAnnotation, WidgetValue, WidgetValue)] = []
        for (key, entry) in tracked {
            var items = entry.items
            for i in items.indices {
                let now = value(of: items[i].annotation)
                if now != items[i].value {
                    changes.append((items[i].annotation, items[i].value, now))
                    items[i].value = now
                }
            }
            tracked[key]?.items = items
        }
        guard !changes.isEmpty else { return }
        controller.isDirty = true
        registerUndo(changes)
    }

    private func registerUndo(_ changes: [(PDFAnnotation, WidgetValue, WidgetValue)]) {
        let undo = controller.undoManager
        undo.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restore(changes.map { ($0.0, $0.2, $0.1) })
            }
        }
        if !undo.isUndoing && !undo.isRedoing { undo.setActionName("Fill Form") }
    }

    /// Sets each annotation to `new` (changes are `(annotation, current, new)`).
    private func restore(_ changes: [(PDFAnnotation, WidgetValue, WidgetValue)]) {
        for (annotation, _, new) in changes {
            setValue(new, on: annotation)
            if let page = annotation.page {
                if var entry = tracked[ObjectIdentifier(page)],
                   let i = entry.items.firstIndex(where: { $0.annotation === annotation }) {
                    entry.items[i].value = new
                    tracked[ObjectIdentifier(page)] = entry
                }
                pdfView.annotationsChanged(on: page)
            }
        }
        controller.isDirty = true
        registerUndo(changes)
    }

    func setValue(_ value: WidgetValue, on annotation: PDFAnnotation) {
        if annotation.widgetFieldType == .button {
            if let state = PDFWidgetCellState(rawValue: value.state) {
                annotation.buttonWidgetState = state
            }
        } else {
            annotation.widgetStringValue = value.string
        }
    }
}
