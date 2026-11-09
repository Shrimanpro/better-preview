import AppKit
import PDFKit

/// Inline editor for a note's or text box's text: an NSTextView placed over
/// the annotation. While it has focus the window is in insert mode, so vim
/// keys type; Esc (handled by the window) or a click elsewhere ends editing.
/// The annotation's contents follow every keystroke, so a save mid-edit
/// keeps the text; undo gets one entry when editing ends.
@MainActor
final class MarkupTextEditor: NSObject, NSTextViewDelegate {
    unowned let feature: MarkupFeature
    let annotation: PDFAnnotation
    let page: PDFPage
    /// Created by this edit: undo removes it, and an empty text box is dropped.
    let isNew: Bool
    private let before: AnnotationState
    private let kind: MarkupKind
    let textView: NSTextView
    private var finished = false

    init(feature: MarkupFeature, annotation: PDFAnnotation, page: PDFPage, isNew: Bool) {
        self.feature = feature
        self.annotation = annotation
        self.page = page
        self.isNew = isNew
        before = AnnotationState(annotation)
        kind = MarkupKind(annotation) ?? .note
        textView = NSTextView(frame: .zero)
        super.init()
        textView.isRichText = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.textContainerInset = NSSize(width: 2, height: 2)
        textView.string = annotation.contents ?? ""
        if kind == .textBox {
            textView.textColor = annotation.fontColor ?? .black
            textView.backgroundColor = NSColor.white.withAlphaComponent(0.9)
            textView.textContainer?.lineFragmentPadding = 2
        } else {
            textView.textColor = .black
            textView.font = .systemFont(ofSize: 13)
            textView.backgroundColor = NSColor(srgbRed: 1, green: 0.97, blue: 0.75, alpha: 1)
        }
        textView.insertionPointColor = .black
        textView.wantsLayer = true
        textView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        textView.layer?.borderWidth = 1
        textView.layer?.shadowOpacity = kind == .note ? 0.25 : 0
        textView.delegate = self
    }

    func start() {
        let pdfView = feature.pdfView
        if kind == .textBox {
            annotation.shouldDisplay = false
            pdfView.annotationsChanged(on: page)
        }
        pdfView.addSubview(textView)
        position()
        pdfView.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
        feature.controller.host?.setMode(.insert)
    }

    /// Follows scrolling and zooming.
    func position() {
        let pdfView = feature.pdfView
        let rect = pdfView.convert(annotation.bounds, from: page)
        if kind == .textBox {
            let scale = pdfView.scaleFactor
            let font = annotation.font ?? .systemFont(ofSize: 12)
            textView.font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale) ?? font
            textView.frame = rect.integral
        } else {
            let size = CGSize(width: 240, height: 140)
            textView.frame = CGRect(x: rect.maxX + 6, y: rect.maxY - size.height, width: size.width, height: size.height)
        }
    }

    func textDidChange(_ notification: Notification) {
        annotation.contents = textView.string
        guard kind == .textBox, let container = textView.textContainer,
              let layout = textView.layoutManager else { return }
        // Grow downwards to fit, keeping the top edge, like Preview.
        layout.ensureLayout(for: container)
        let needed = (layout.usedRect(for: container).height + textView.textContainerInset.height * 2 + 2)
            / max(feature.pdfView.scaleFactor, 0.01)
        var bounds = annotation.bounds
        if needed > bounds.height {
            bounds.origin.y = bounds.maxY - ceil(needed)
            bounds.size.height = ceil(needed)
            annotation.bounds = bounds
            position()
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        commit()
    }

    /// Ends editing and records the result.
    func commit() { finish(keep: true) }

    /// Ends editing without recording anything (document reloaded or the
    /// annotation removed).
    func cancel() { finish(keep: false) }

    private func finish(keep: Bool) {
        guard !finished else { return }
        finished = true
        if feature.editor === self { feature.editor = nil }
        let text = textView.string
        let pdfView = feature.pdfView
        textView.delegate = nil
        if pdfView.window?.firstResponder === textView { pdfView.window?.makeFirstResponder(pdfView) }
        textView.removeFromSuperview()
        annotation.shouldDisplay = true
        if feature.controller.host?.mode == .insert { feature.controller.host?.setMode(.normal) }
        defer { feature.refreshOverlay() }
        guard keep else {
            pdfView.annotationsChanged(on: page)
            return
        }
        annotation.contents = text
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if kind == .textBox, empty {
            if isNew {
                page.removeAnnotation(annotation)
                feature.select(nil)
                pdfView.annotationsChanged(on: page)
            } else {
                before.apply(to: annotation)
                feature.remove([(annotation, page)], name: "Delete Text")
            }
        } else if isNew {
            page.removeAnnotation(annotation)
            feature.insert([(annotation, page)], name: kind == .note ? "Add Note" : "Add Text")
        } else {
            feature.recordChange(annotation, from: before, name: "Edit Text")
            pdfView.annotationsChanged(on: page)
        }
    }
}

extension MarkupFeature {
    /// Starts editing a note's or text box's text. `isNew`: the annotation
    /// was just put on its page without an undo entry.
    func beginEditing(_ annotation: PDFAnnotation, isNew: Bool) {
        editor?.commit()
        guard let page = annotation.page else { return }
        let editor = MarkupTextEditor(feature: self, annotation: annotation, page: page, isNew: isNew)
        self.editor = editor
        editor.start()
        refreshOverlay()
    }
}
