import AppKit
import BPCore
import PDFKit

/// `BP_SELFTEST=markup` or `BP_MARKUP_SELFTEST=1`: drives the markup feature in the live window with
/// synthesized mouse events and direct calls, one step per run-loop turn (so
/// each step is its own undo group), then saves to build/tmp/markup-selftest.pdf
/// and re-reads it with PDFKit to check subtypes, bounds and colours.
/// Prints PASS/FAIL lines and "MARKUP SELFTEST PASS|FAIL" to stderr and exits,
/// unless a BP_SCRIPT is running (so it can snapshot the result afterwards).
@MainActor
enum MarkupSelfTest {
    private static var scheduled = false

    static func scheduleIfRequested(_ feature: MarkupFeature) {
        guard !scheduled, PDFSelfTest.featureRequested("markup", variable: "BP_MARKUP_SELFTEST") else { return }
        scheduled = true
        let delay = Double(ProcessInfo.processInfo.environment["BP_SELFTEST_DELAY"] ?? "") ?? 1.2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak feature] in
            guard let feature else { return }
            Run(feature: feature).start()
        }
    }

    /// Where a nil-targeted menu action goes when `window` is key: the
    /// first responder's chain, then the window's delegate (what AppKit
    /// does; a headless run's window is not key, so it is walked by hand).
    static func chainTarget(for selector: Selector, in window: DocumentWindowController) -> AnyObject? {
        var responder: NSResponder? = window.window?.firstResponder
        while let r = responder {
            if r.responds(to: selector) { return r }
            responder = r.nextResponder
        }
        if let delegate = window.window?.delegate as AnyObject?, delegate.responds(to: selector) { return delegate }
        return nil
    }

    @MainActor
    private final class Run {
        let feature: MarkupFeature
        var ok = true
        var steps: [(grouped: Bool, run: () -> Void)] = []

        func add(_ body: @escaping () -> Void) { steps.append((true, body)) }
        /// Steps that call undo/redo run outside an undo group.
        func addUndo(_ body: @escaping () -> Void) { steps.append((false, body)) }
        var page: PDFPage!
        var visible = CGRect.zero
        var created: [String: PDFAnnotation] = [:]
        var baseline = 0

        init(feature: MarkupFeature) { self.feature = feature }

        var pdfView: BPPDFView { feature.pdfView }
        var controller: PDFDocumentController { feature.controller }
        var undo: UndoManager { controller.undoManager }

        func log(_ s: String) { PDFSelfTest.log(s) }
        func check(_ c: Bool, _ m: String) { ok = PDFSelfTest.check(c, "markup: " + m) && ok }

        func markup(on page: PDFPage) -> [PDFAnnotation] { page.annotations.filter { MarkupKind($0) != nil } }
        var count: Int { markup(on: page).count }

        /// A point in page space at fractions (fx, fy) of the visible part of the page.
        func at(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: visible.minX + visible.width * fx, y: visible.minY + visible.height * fy)
        }

        func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
            let inView = pdfView.convert(p, from: page)
            return NSEvent.mouseEvent(with: type, location: pdfView.convert(inView, to: nil), modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: pdfView.window?.windowNumber ?? 0, context: nil,
                                      eventNumber: 0, clickCount: clicks, pressure: 1)!
        }

        /// Press at a, drag through to b, release; every event must be consumed.
        func drag(_ a: CGPoint, _ b: CGPoint, through extra: [CGPoint] = [], clicks: Int = 1) -> Bool {
            var consumed = feature.handleMouse(event(.leftMouseDown, a, clicks: clicks))
            for p in extra + [b] { consumed = feature.handleMouse(event(.leftMouseDragged, p)) && consumed }
            return feature.handleMouse(event(.leftMouseUp, b)) && consumed
        }

        func action(_ name: ActionName) { _ = controller.perform(ActionInvocation(name)) }

        func newest() -> PDFAnnotation? { markup(on: page).last }

        func start() {
            log("markup selftest: start")
            guard let document = controller.document, let first = document.page(at: 0) else {
                check(false, "document")
                return finish()
            }
            page = first
            // One undo group per step, as one user gesture would make.
            undo.groupsByEvent = false
            controller.go(to: DocumentPosition(page: 0), animated: false)
            pdfView.layoutDocumentView()
            visible = pdfView.convert(pdfView.bounds, to: page).intersection(page.bounds(for: .cropBox))
                .insetBy(dx: 20, dy: 20)
            check(visible.width > 100 && visible.height > 100, "page 1 visible (\(visible.integral))")
            baseline = count

            // Idle mouse handling must not consume anything.
            add { [self] in
                check(!feature.handleMouse(event(.mouseMoved, at(0.5, 0.5))), "idle mouseMoved not consumed")
                check(!feature.handleMouse(event(.leftMouseDragged, at(0.5, 0.5))), "idle drag not consumed")
            }
            // Text markup from a selection, one line each.
            add { [self] in
                let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
                let textLines = lines.filter { !($0.string ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
                check(textLines.count >= 3, "page has \(textLines.count) text lines")
                guard textLines.count >= 3 else { return }
                for (i, kind) in [MarkupTool.highlight, .underline, .strikethrough].enumerated() {
                    pdfView.setCurrentSelection(textLines[i], animate: false)
                    action(kind == .highlight ? .annotateHighlight : kind == .underline ? .annotateUnderline
                           : .annotateStrikethrough)
                    created[kind.rawValue] = newest()
                }
                check(count == baseline + 3, "3 text markups added")
                check(created["highlight"]?.type == "Highlight" && created["underline"]?.type == "Underline"
                      && created["strikethrough"]?.type == "StrikeOut", "text markup subtypes")
                check(feature.tool == nil, "selection markup leaves no tool armed")
            }
            // Armed highlighter with no selection: next drag-select is highlighted.
            add { [self] in
                pdfView.clearSelection()
                action(.annotateHighlight)
                check(feature.tool == .highlight && controller.status.flags.contains("highlight"),
                      "highlight armed, status flag shown")
                let lines = page.selection(for: page.bounds(for: .cropBox))?.selectionsByLine() ?? []
                if lines.count > 4 { pdfView.setCurrentSelection(lines[4], animate: false) }
                check(!feature.handleMouse(event(.leftMouseUp, at(0.5, 0.5))), "armed highlighter lets PDFView select")
            }
            add { [self] in
                check(count == baseline + 4, "armed highlighter marked up the drag selection")
                action(.toolSelect)
                check(feature.tool == nil, "tool-select disarms")
            }
            // Shapes, lines, ink through the mouse path.
            let shapes: [(MarkupTool, ActionName, CGPoint, CGPoint)] = [
                (.rectangle, .toolRectangle, at(0.05, 0.05), at(0.25, 0.2)),
                (.oval, .toolOval, at(0.3, 0.05), at(0.5, 0.2)),
                (.line, .toolLine, at(0.55, 0.05), at(0.7, 0.2)),
                (.arrow, .toolArrow, at(0.75, 0.05), at(0.95, 0.2)),
            ]
            for (tool, name, a, b) in shapes {
                add { [self] in
                    action(name)
                    check(feature.tool == tool, "\(tool) armed")
                    // The first one goes through BPPDFView's real routing.
                    if tool == .rectangle {
                        pdfView.mouseDown(with: event(.leftMouseDown, a))
                        pdfView.mouseDragged(with: event(.leftMouseDragged, b))
                        pdfView.mouseUp(with: event(.leftMouseUp, b))
                    } else {
                        check(drag(a, b), "\(tool) drag consumed")
                    }
                    created[tool.rawValue] = newest()
                    check(feature.tool == nil && feature.selected === created[tool.rawValue], "\(tool) created and selected")
                }
            }
            add { [self] in
                action(.toolInk)
                let pts = (0...20).map { i in at(0.1 + CGFloat(i) * 0.02, 0.3 + 0.05 * sin(CGFloat(i) / 3)) }
                check(drag(pts[0], pts.last!, through: Array(pts.dropFirst().dropLast())), "ink drag consumed")
                created["ink"] = newest()
                check(created["ink"]?.type == "Ink" && feature.tool == .ink, "ink created, tool stays armed")
                action(.toolInk)
            }
            // Note and text box: editing switches to insert mode.
            add { [self] in
                action(.toolNote)
                check(feature.handleMouse(event(.leftMouseDown, at(0.6, 0.35))), "note click consumed")
                _ = feature.handleMouse(event(.leftMouseUp, at(0.6, 0.35)))
                check(feature.editor != nil && controller.host?.mode == .insert, "note editing in insert mode")
                feature.editor?.textView.insertText("Hello note", replacementRange: NSRange(location: NSNotFound, length: 0))
                created["note"] = feature.editor?.annotation
                feature.editor?.commit()
                check(feature.editor == nil && controller.host?.mode != .insert, "note editing ended, normal mode")
                check(created["note"]?.contents == "Hello note" && created["note"]?.page === page, "note text kept")
            }
            add { [self] in
                action(.toolText)
                check(drag(at(0.7, 0.4), at(0.95, 0.45)), "text box drag consumed")
                check(feature.editor != nil && controller.host?.mode == .insert, "text box editing in insert mode")
                feature.editor?.textView.insertText("Boxed text", replacementRange: NSRange(location: NSNotFound, length: 0))
                created["text"] = feature.editor?.annotation
                // Esc as the window does it: focus back to the document.
                pdfView.window?.makeFirstResponder(pdfView)
                controller.host?.setMode(.normal)
                check(feature.editor == nil, "text box editing ends when focus leaves")
                check(created["text"]?.contents == "Boxed text" && created["text"]?.page === page, "text box text kept")
                check(count == baseline + 4 + 7, "all kinds created (\(count - baseline))")
            }
            // Move and resize the rectangle with the mouse, in select mode.
            add { [self] in
                guard let rect = created["rectangle"] else { return check(false, "rectangle exists") }
                feature.select(nil)
                let before = rect.bounds
                let center = CGPoint(x: before.midX, y: before.midY)
                check(drag(center, CGPoint(x: center.x + 30, y: center.y + 20)), "move drag consumed")
                check(abs(rect.bounds.minX - before.minX - 30) < 0.01 && abs(rect.bounds.minY - before.minY - 20) < 0.01,
                      "rectangle moved by (30, 20)")
            }
            add { [self] in
                guard let rect = created["rectangle"] else { return }
                let before = rect.bounds
                let corner = CGPoint(x: before.maxX, y: before.minY)
                check(drag(corner, CGPoint(x: corner.x + 40, y: corner.y - 10)), "resize drag consumed")
                check(abs(rect.bounds.width - before.width - 40) < 0.01 && abs(rect.bounds.height - before.height - 10) < 0.01,
                      "rectangle resized by (40, 10)")
            }
            // Inspector edits the selection.
            add { [self] in
                guard let rect = created["rectangle"] else { return }
                feature.select(rect)
                action(.toggleInspector)
                check(feature.inspector?.isVisible == true, "inspector shown")
                feature.setColor(.systemBlue)
                feature.setLineWidth(4)
                feature.setFill(NSColor(srgbRed: 1, green: 1, blue: 0.6, alpha: 1))
                check(rect.border?.lineWidth == 4 && rect.interiorColor != nil, "inspector restyled rectangle")
            }
            addUndo { [self] in
                undo.undo()
                check(created["rectangle"]?.border?.lineWidth == 2 && created["rectangle"]?.interiorColor == nil,
                      "one undo reverts the whole restyle step")
                undo.redo()
                action(.toggleInspector)
                check(feature.inspector?.isVisible == false, "inspector hidden")
            }
            // Undo everything, then redo everything.
            addUndo { [self] in
                let full = count
                var undos = 0
                while undo.canUndo, undos < 100 {
                    undo.undo()
                    undos += 1
                }
                check(count == baseline && undos >= 12, "undo all (\(undos) steps) removes every annotation")
                for _ in 0..<undos { undo.redo() }
                check(count == full, "redo all restores them (\(count - baseline))")
                check(created["rectangle"]?.border?.lineWidth == 4, "redo restores the restyle")
                check(controller.isDirty, "document dirty")
            }
            // Delete and undo.
            add { [self] in
                feature.select(created["oval"])
                let n = count
                action(.annotationDelete)
                check(count == n - 1 && feature.selected == nil, "annotation-delete removes the selection")
            }
            addUndo { [self] in
                undo.undo()
                check(created["oval"]?.page === page, "undo brings the oval back")
            }
            add { [self] in saveAndReload() }
            // Page renders (PDFKit tiles are not in window snapshots).
            add { [self] in
                render("markup-page.png")
                action(.toggleRecolor)
                render("markup-page-recolor.png")
                action(.toggleRecolor)
            }
            // Editing a text box: Edit menu commands go to the editor, and a
            // save mid-edit commits it (the box is hidden only while editing).
            add { [self] in
                guard let text = created["text"], let window = controller.host as? DocumentWindowController else {
                    return check(false, "text box and window")
                }
                let undoable = undo.canUndo
                let n = count
                feature.beginEditing(text, isNew: false)
                check(feature.editor != nil && !text.shouldDisplay && window.mode == .insert,
                      "editing a text box hides it and enters insert mode")
                guard let editor = feature.editor else { return }
                editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
                window.performMenuAction(ActionMenuItem("Select All", .selectAll))
                check(editor.textView.selectedRange().length == (editor.textView.string as NSString).length
                      && pdfView.currentSelection == nil, "Select All goes to the text editor, not the PDF")
                window.performMenuAction(ActionMenuItem("Undo", .undo))
                // Nil-targeted Cut/Paste/Delete reach the editor.
                for selector in [#selector(NSText.cut(_:)), #selector(NSText.paste(_:)), #selector(NSText.delete(_:))] {
                    check(MarkupSelfTest.chainTarget(for: selector, in: window) === editor.textView, "\(selector) goes to the text editor")
                }
                check(count == n && undo.canUndo == undoable && feature.editor === editor,
                      "Undo while editing text leaves the document's undo stack alone")
                editor.textView.insertText("Saved mid-edit", replacementRange: NSRange(location: NSNotFound, length: 0))
                let url = PDFSelfTest.outputDirectory.appendingPathComponent("markup-midedit.pdf")
                try? FileManager.default.removeItem(at: url)
                // What every write does first (save-as would move the window
                // to the copy, so the copy is written directly).
                window.commitPendingEdits()
                try? controller.save(to: url)
                check(feature.editor == nil && text.shouldDisplay && window.mode == .normal,
                      "saving mid-edit ends the edit and shows the box again")
                check(MarkupSelfTest.chainTarget(for: #selector(NSText.delete(_:)), in: window) === window,
                      "Edit > Delete without a text view goes to the window (annotation-delete)")
                check(MarkupSelfTest.chainTarget(for: #selector(NSText.paste(_:)), in: window) == nil,
                      "Paste is disabled without a text view")
                let saved = PDFDocument(url: url)?.page(at: 0)?.annotations.first { $0.type == "FreeText" && $0.contents == "Saved mid-edit" }
                check(saved != nil && saved?.shouldDisplay == true, "the saved text box is visible (not Hidden)")
            }
            add { [self] in
                action(.toolRectangle)
                _ = controller.perform(ActionInvocation(.abort))
                check(feature.tool == nil, "abort disarms the tool")
                feature.select(created["ink"])
                feature.documentDidReload()
                check(feature.selected == nil && feature.overlay?.superview == nil, "reload clears selection and overlay")
                feature.select(created["arrow"])
            }
            next()
        }

        func next() {
            guard !steps.isEmpty else { return finish() }
            let step = steps.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                // Each step is one undo group, as one user gesture would be.
                if step.grouped { undo.beginUndoGrouping() }
                step.run()
                if step.grouped { undo.endUndoGrouping() }
                next()
            }
        }

        func saveAndReload() {
            let dir = PDFSelfTest.outputDirectory
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("markup-selftest.pdf")
            try? FileManager.default.removeItem(at: url)
            do {
                try controller.save(to: url)
            } catch {
                return check(false, "save: \(error)")
            }
            guard let saved = PDFDocument(url: url), let savedPage = saved.page(at: 0) else {
                return check(false, "reopen saved file")
            }
            let original = markup(on: page)
            let reread = markup(on: savedPage)
            check(reread.count == original.count, "saved \(reread.count) of \(original.count) annotations")
            let types = Set(reread.compactMap(\.type))
            for t in ["Highlight", "Underline", "StrikeOut", "Square", "Circle", "Line", "Ink", "Text", "FreeText"] {
                check(types.contains(t), "saved file has /\(t)")
            }
            for (name, a) in created.sorted(by: { $0.key < $1.key }) {
                // PDFKit writes notes at its icon size (24 x 24) plus a /Popup.
                let twin = a.type == "Text" ? reread.first { $0.type == "Text" && $0.contents == a.contents }
                    : reread.first { $0.type == a.type && close($0.bounds, a.bounds) }
                guard let b = twin else {
                    check(false, "\(name): no saved twin with bounds \(a.bounds.integral)")
                    continue
                }
                let colorA = a.type == "FreeText" ? a.fontColor : a.color
                let colorB = b.type == "FreeText" ? b.fontColor : b.color
                check(sameColor(colorA, colorB), "\(name): bounds and colour round-trip")
                if name == "arrow" { check(b.endLineStyle == .closedArrow, "arrow head round-trips") }
                if name == "line" || name == "arrow" {
                    check(hypot(b.startPoint.x - a.startPoint.x, b.startPoint.y - a.startPoint.y) < 1
                          && hypot(b.endPoint.x - a.endPoint.x, b.endPoint.y - a.endPoint.y) < 1, "\(name) endpoints round-trip")
                }
                if name == "rectangle" {
                    check(b.border?.lineWidth == 4 && sameColor(a.interiorColor, b.interiorColor), "rectangle width and fill round-trip")
                }
                if name == "text" {
                    check(b.contents == "Boxed text" && abs((b.font?.pointSize ?? 0) - (a.font?.pointSize ?? -1)) < 0.5,
                          "text box contents and font size round-trip")
                }
                if name == "note" { check(b.contents == "Hello note", "note contents round-trip") }
                if name == "ink" {
                    let pa = a.paths?.first?.bounds ?? .null, pb = b.paths?.first?.bounds ?? .zero
                    check(close(pa, pb, tolerance: 2), "ink path round-trips (\(pa.integral) vs \(pb.integral))")
                }
                if name == "highlight" {
                    check((b.quadrilateralPoints?.count ?? 0) == (a.quadrilateralPoints?.count ?? -1), "highlight quads round-trip")
                }
            }
        }

        func render(_ name: String) {
            let image = page.renderedThumbnail(of: CGSize(width: 900, height: 1200), for: .cropBox)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return check(false, "render \(name)") }
            try? png.write(to: PDFSelfTest.outputDirectory.appendingPathComponent(name))
        }

        func close(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0.6) -> Bool {
            abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
                && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
        }

        func sameColor(_ a: NSColor?, _ b: NSColor?) -> Bool {
            guard let a = a?.usingColorSpace(.sRGB), let b = b?.usingColorSpace(.sRGB) else { return a == nil && b == nil }
            return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
                && abs(a.blueComponent - b.blueComponent) < 0.02
        }

        func finish() {
            undo.groupsByEvent = true
            log(ok ? "MARKUP SELFTEST PASS" : "MARKUP SELFTEST FAIL")
            // Stay open only when a BP_SCRIPT wants to look at the result.
            if ProcessInfo.processInfo.environment["BP_SCRIPT"] == nil { exit(ok ? 0 : 1) }
        }
    }
}
