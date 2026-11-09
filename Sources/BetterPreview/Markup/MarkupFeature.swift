import AppKit
import BPCore
import PDFKit

/// PDF markup, like Preview's Markup toolbar: text highlight / underline /
/// strikethrough, notes, text boxes, rectangles, ovals, lines, arrows and
/// freehand ink; selecting, moving, resizing, deleting and restyling
/// annotations; all undoable and saved as standard PDF annotations.
///
/// Everything is created lazily: until a tool is armed or an annotation is
/// clicked there is no overlay, no observer and no panel, and `handleMouse`
/// returns at once for everything but a mouse-down.
@MainActor
final class MarkupFeature: PDFFeature {
    unowned let controller: PDFDocumentController

    /// The armed tool; nil = select.
    private(set) var tool: MarkupTool?
    var style = MarkupStyle()
    /// The selected annotation (shown with handles in the overlay).
    private(set) var selected: PDFAnnotation?
    var selectedPage: PDFPage? { selected?.page }
    /// The mouse gesture in progress.
    var drag: MarkupDrag?
    /// The note / text box being edited.
    var editor: MarkupTextEditor?
    var overlay: MarkupOverlay?
    var inspector: MarkupInspector?
    private var observers: [NSObjectProtocol] = []
    private var keyHandlerInstalled = false
    /// A drag-select with a text-markup tool armed is waiting for PDFView to
    /// finish the selection.
    private var pendingTextMarkup = false

    init(controller: PDFDocumentController) {
        self.controller = controller
        MarkupSelfTest.scheduleIfRequested(self)
    }

    var pdfView: BPPDFView { controller.pdfView }
    var undoManager: UndoManager { controller.undoManager }

    // MARK: PDFFeature

    func handle(_ invocation: ActionInvocation) -> Bool {
        switch invocation.action.name {
        case .annotateHighlight: annotateSelection(.highlight)
        case .annotateUnderline: annotateSelection(.underline)
        case .annotateStrikethrough: annotateSelection(.strikethrough)
        case .toolSelect: setTool(nil)
        case .toolNote: toggleTool(.note)
        case .toolText: toggleTool(.text)
        case .toolRectangle: toggleTool(.rectangle)
        case .toolOval: toggleTool(.oval)
        case .toolLine: toggleTool(.line)
        case .toolArrow: toggleTool(.arrow)
        case .toolInk: toggleTool(.ink)
        case .annotationDelete:
            deleteSelected()
        case .toggleInspector: toggleInspector()
        case .abort:
            // Shared with other features and the controller: never consume.
            abort()
            return false
        default: return false
        }
        return true
    }

    var statusFlags: [String] {
        guard let tool else { return [] }
        return [tool.rawValue]
    }

    func handleMouse(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown: return mouseDown(event)
        case .leftMouseDragged:
            guard drag != nil else { return false }
            mouseDragged(event)
            return true
        case .leftMouseUp:
            if drag != nil {
                mouseUp(event)
                return true
            }
            if let tool, tool.isTextMarkup { scheduleTextMarkup() }
            return false
        default: return false
        }
    }

    func commitPendingEdits() {
        editor?.commit()
    }

    func tearDown() {
        editor?.cancel()
        editor = nil
        drag = nil
        overlay?.removeFromSuperview()
        updateObservers(needed: false)
    }

    func documentDidReload() {
        // The annotation objects belong to the old document.
        editor?.cancel()
        editor = nil
        drag = nil
        selected = nil
        pendingTextMarkup = false
        if controller.host?.mode == .insert { controller.host?.setMode(.normal) }
        refreshOverlay()
        inspector?.refresh()
    }

    // MARK: Tools

    func setTool(_ new: MarkupTool?) {
        editor?.commit()
        drag = nil
        tool = new
        if new != nil, !(new?.isTextMarkup ?? false) { select(nil) }
        refreshOverlay()
        inspector?.refresh()
        controller.scheduleStatusUpdate()
    }

    private func toggleTool(_ new: MarkupTool) {
        setTool(tool == new ? nil : new)
    }

    private func abort() {
        if editor != nil {
            editor?.commit()
        } else if tool != nil {
            setTool(nil)
        } else if selected != nil {
            select(nil)
        }
    }

    /// `gh` / `gu` / `gs`: mark up the text selection, or with no selection
    /// arm the tool so the next drag-select is marked up (Preview's
    /// highlighter mode, which stays on until switched off).
    private func annotateSelection(_ kind: MarkupTool) {
        if let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            applyTextMarkup(kind, to: selection)
            pdfView.clearSelection()
        } else {
            toggleTool(kind)
        }
    }

    @discardableResult
    func applyTextMarkup(_ kind: MarkupTool, to selection: PDFSelection) -> [PDFAnnotation] {
        let items = MarkupFactory.textMarkup(kind, selection: selection, style: style)
        guard !items.isEmpty else { return [] }
        insert(items, name: kind.rawValue.capitalized)
        return items.map(\.0)
    }

    /// PDFView finishes its drag-select in its own mouseUp, after us.
    private func scheduleTextMarkup() {
        guard !pendingTextMarkup else { return }
        pendingTextMarkup = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            pendingTextMarkup = false
            guard let tool, tool.isTextMarkup, let selection = pdfView.currentSelection,
                  !(selection.string ?? "").isEmpty else { return }
            applyTextMarkup(tool, to: selection)
            pdfView.clearSelection()
        }
    }

    // MARK: Selection

    func select(_ annotation: PDFAnnotation?) {
        guard annotation !== selected else { return }
        selected = annotation
        if annotation != nil { installKeyHandler() }
        refreshOverlay()
        inspector?.refresh()
    }

    private func deleteSelected() {
        guard let annotation = selected, let page = annotation.page else {
            controller.host?.showMessage("No annotation selected", isError: true)
            return
        }
        var items = [(annotation, page)]
        // A note's popup (PDFKit adds one when saving) goes with it.
        if let popup = annotation.popup, popup.page === page { items.append((popup, page)) }
        remove(items, name: "Delete Annotation")
    }

    /// Delete / Forward Delete remove the selected annotation. Installed on
    /// first selection, chaining whatever handler was there.
    private func installKeyHandler() {
        guard !keyHandlerInstalled else { return }
        keyHandlerInstalled = true
        let previous = pdfView.keyHandler
        pdfView.keyHandler = { [weak self] event in
            if let self, self.selected != nil, self.editor == nil,
               event.keyCode == 51 || event.keyCode == 117,
               event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
                self.deleteSelected()
                return true
            }
            return previous?(event) ?? false
        }
    }

    // MARK: Undoable edits

    /// Adds annotations; undo removes them.
    func insert(_ items: [(PDFAnnotation, PDFPage)], name: String) {
        for (annotation, page) in items { page.addAnnotation(annotation) }
        didEdit(items.map(\.1))
        registerUndo(name) { $0.remove(items, name: name) }
    }

    /// Removes annotations; undo puts them back.
    func remove(_ items: [(PDFAnnotation, PDFPage)], name: String) {
        let items = items.map { ($0.0, $0.0.page ?? $0.1) }
        if let selected, items.contains(where: { $0.0 === selected }) { select(nil) }
        if let editor, items.contains(where: { $0.0 === editor.annotation }) {
            self.editor = nil
            editor.cancel()
        }
        for (annotation, page) in items { page.removeAnnotation(annotation) }
        didEdit(items.map(\.1))
        registerUndo(name) { $0.insert(items, name: name) }
    }

    /// Records a change already made to `annotation` (from `before` to its
    /// current state); undo restores `before`. No-op when nothing changed.
    func recordChange(_ annotation: PDFAnnotation, from before: AnnotationState, name: String) {
        let after = AnnotationState(annotation)
        guard !before.sameAs(after) else { return }
        registerStateUndo(annotation, restoring: before, redo: after, name: name)
        if let page = annotation.page { didEdit([page]) }
    }

    /// Applies a change with `body` and records it.
    func change(_ annotation: PDFAnnotation, name: String, _ body: (PDFAnnotation) -> Void) {
        let before = AnnotationState(annotation)
        body(annotation)
        recordChange(annotation, from: before, name: name)
    }

    private func registerStateUndo(_ annotation: PDFAnnotation, restoring state: AnnotationState,
                                   redo other: AnnotationState, name: String) {
        registerUndo(name) { target in
            state.apply(to: annotation)
            target.registerStateUndo(annotation, restoring: other, redo: state, name: name)
            if let page = annotation.page { target.didEdit([page]) }
        }
    }

    private func registerUndo(_ name: String, _ handler: @escaping (MarkupFeature) -> Void) {
        let manager = undoManager
        // Without event grouping (scripts, the self-test) there may be no open group.
        let ownGroup = !manager.groupsByEvent && manager.groupingLevel == 0
        if ownGroup { manager.beginUndoGrouping() }
        manager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { handler(target) }
        }
        manager.setActionName(name)
        if ownGroup { manager.endUndoGrouping() }
    }

    /// After any edit: redraw, mark dirty, refresh selection chrome.
    func didEdit(_ pages: [PDFPage]) {
        var seen = Set<ObjectIdentifier>()
        for page in pages where seen.insert(ObjectIdentifier(page)).inserted {
            pdfView.annotationsChanged(on: page)
        }
        controller.isDirty = true
        overlay?.needsDisplay = true
        inspector?.refresh()
        controller.scheduleStatusUpdate()
    }

    // MARK: Overlay

    /// Shows the overlay only while there is something to draw, and only then
    /// listens to scrolling and zooming.
    func refreshOverlay() {
        let needed = selected != nil || drag?.drawsPreview == true
        if needed {
            if overlay == nil {
                let view = MarkupOverlay(feature: self)
                view.frame = pdfView.bounds
                view.autoresizingMask = [.width, .height]
                overlay = view
            }
            if overlay?.superview == nil, let overlay {
                pdfView.addSubview(overlay)
            }
            overlay?.needsDisplay = true
        } else {
            overlay?.removeFromSuperview()
        }
        updateObservers(needed: needed || editor != nil)
    }

    private func updateObservers(needed: Bool) {
        if !needed {
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers.removeAll()
            return
        }
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.viewportChanged() }
        }
        if let clip = pdfView.enclosedScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                queue: .main, using: refresh))
        }
        observers.append(center.addObserver(forName: .PDFViewScaleChanged, object: pdfView,
                                            queue: .main, using: refresh))
    }

    private func viewportChanged() {
        overlay?.needsDisplay = true
        editor?.position()
    }
}

extension AnnotationState {
    func sameAs(_ o: AnnotationState) -> Bool {
        bounds == o.bounds && color == o.color && interiorColor == o.interiorColor && lineWidth == o.lineWidth
            && font == o.font && fontColor == o.fontColor && contents == o.contents
            && startPoint == o.startPoint && endPoint == o.endPoint
            && (paths?.map(\.bounds) ?? []) == (o.paths?.map(\.bounds) ?? [])
            && (paths?.map(\.lineWidth) ?? []) == (o.paths?.map(\.lineWidth) ?? [])
    }
}
