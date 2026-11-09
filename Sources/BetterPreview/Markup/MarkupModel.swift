import AppKit
import PDFKit

/// The armed markup tool. `nil` in the feature means "select" (Preview's
/// arrow): clicks select annotations, drags select text.
enum MarkupTool: String {
    case highlight, underline, strikethrough
    case note, text, rectangle, oval, line, arrow, ink

    /// Text-markup tools apply to the text selection instead of drawing.
    var isTextMarkup: Bool { self == .highlight || self == .underline || self == .strikethrough }

    /// Tools that stay armed after use (Preview's highlighter and sketch
    /// modes). The others insert one annotation and return to select.
    var isSticky: Bool { isTextMarkup || self == .ink }

    var subtype: PDFAnnotationSubtype {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikethrough: .strikeOut
        case .note: .text
        case .text: .freeText
        case .rectangle: .square
        case .oval: .circle
        case .line, .arrow: .line
        case .ink: .ink
        }
    }
}

/// What kind of markup an annotation is, as far as editing is concerned.
/// Annotations of other subtypes (links, form widgets, popups) are ignored.
enum MarkupKind {
    case textMarkup, note, textBox, shape, line, ink

    init?(_ annotation: PDFAnnotation) {
        // `type` is the subtype without the leading slash.
        switch annotation.type ?? "" {
        case "Highlight", "Underline", "StrikeOut", "Squiggly": self = .textMarkup
        case "Text": self = .note
        case "FreeText": self = .textBox
        case "Square", "Circle": self = .shape
        case "Line": self = .line
        case "Ink": self = .ink
        default: return nil
        }
    }

    /// Kinds whose bounds can be resized by corner handles.
    var hasCornerHandles: Bool { self == .shape || self == .textBox || self == .ink }
    var isMovable: Bool { self != .textMarkup }
}

/// Style applied to new annotations and, from the inspector, to the selected one.
struct MarkupStyle {
    var highlightColor = NSColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1)
    var underlineColor = NSColor(srgbRed: 0.1, green: 0.55, blue: 0.1, alpha: 1)
    var strikeColor = NSColor(srgbRed: 0.85, green: 0.1, blue: 0.1, alpha: 1)
    var noteColor = NSColor(srgbRed: 1, green: 0.9, blue: 0.3, alpha: 1)
    /// Stroke colour of shapes, lines, arrows and ink.
    var strokeColor = NSColor(srgbRed: 0.9, green: 0.15, blue: 0.1, alpha: 1)
    /// Interior of rectangles and ovals; nil = no fill.
    var fillColor: NSColor?
    var lineWidth: CGFloat = 2
    var fontName = "Helvetica"
    var fontSize: CGFloat = 14
    var textColor = NSColor.black

    var font: NSFont { NSFont(name: fontName, size: fontSize) ?? .systemFont(ofSize: fontSize) }

    func color(for tool: MarkupTool) -> NSColor {
        switch tool {
        case .highlight: highlightColor
        case .underline: underlineColor
        case .strikethrough: strikeColor
        case .note: noteColor
        case .text: textColor
        default: strokeColor
        }
    }
}

/// Everything editing can change on an annotation, for undo.
struct AnnotationState {
    var bounds: CGRect
    var color: NSColor
    var interiorColor: NSColor?
    var lineWidth: CGFloat?
    var font: NSFont?
    var fontColor: NSColor?
    var contents: String?
    var startPoint: CGPoint
    var endPoint: CGPoint
    var paths: [NSBezierPath]?

    @MainActor
    init(_ a: PDFAnnotation) {
        bounds = a.bounds
        color = a.color
        interiorColor = a.interiorColor
        lineWidth = a.border?.lineWidth
        font = a.font
        fontColor = a.fontColor
        contents = a.contents
        startPoint = a.startPoint
        endPoint = a.endPoint
        paths = a.paths?.map { $0.copy() as! NSBezierPath }
    }

    @MainActor
    func apply(to a: PDFAnnotation) {
        a.bounds = bounds
        a.color = color
        if a.interiorColor != interiorColor { a.interiorColor = interiorColor }
        if let lineWidth {
            let border = a.border ?? PDFBorder()
            border.lineWidth = lineWidth
            a.border = border
        }
        if let font, a.font != font { a.font = font }
        if let fontColor, a.fontColor != fontColor { a.fontColor = fontColor }
        if a.contents != contents { a.contents = contents }
        if MarkupKind(a) == .line {
            a.startPoint = startPoint
            a.endPoint = endPoint
        }
        if let paths {
            for old in a.paths ?? [] { a.remove(old) }
            for path in paths { a.add(path.copy() as! NSBezierPath) }
        }
    }
}

extension CGRect {
    init(corner a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
