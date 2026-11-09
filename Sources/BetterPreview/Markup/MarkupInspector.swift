import AppKit
import PDFKit

/// Floating style panel (`toggle-inspector`, default `i`): colour, fill, line
/// width and font. Edits the selected annotation (undoable) and sets the
/// style of new annotations. Created on first use; never takes key focus
/// unless the colour well needs it, so vim keys keep going to the document.
@MainActor
final class MarkupInspector: NSObject {
    private unowned let feature: MarkupFeature
    let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let colorWell = NSColorWell(style: .minimal)
    private let fillWell = NSColorWell(style: .minimal)
    private let widthPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizePopup = NSPopUpButton()
    private var colorRow: NSView!
    private var fillRow: NSView!
    private var widthRow: NSView!
    private var fontRow: NSView!

    static let swatches: [NSColor] = [
        (1, 0.85, 0.1), (0.35, 0.8, 0.3), (0.3, 0.6, 1), (1, 0.45, 0.7), (0.9, 0.15, 0.1),
        (0.6, 0.35, 0.85), (0, 0, 0), (1, 1, 1),
    ].map { NSColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }
    static let widths: [CGFloat] = [0.5, 1, 2, 3, 4, 6, 8, 12]
    static let sizes: [CGFloat] = [9, 10, 11, 12, 14, 16, 18, 24, 36, 48, 72]
    static let fonts = ["Helvetica", "Helvetica Neue", "Avenir Next", "Gill Sans", "Times New Roman",
                        "Georgia", "Palatino", "Courier", "Menlo", "Marker Felt"]

    init(feature: MarkupFeature) {
        self.feature = feature
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 200),
                        styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        super.init()
        panel.title = "Markup"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        buildContent()
    }

    var isVisible: Bool { panel.isVisible }

    func show(near window: NSWindow?) {
        refresh()
        if let window, !panel.isVisible {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 60))
        }
        panel.orderFront(nil)
    }

    func hide() { panel.orderOut(nil) }

    // MARK: Layout

    private func buildContent() {
        titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.textColor = .secondaryLabelColor

        colorWell.target = self
        colorWell.action = #selector(colorWellChanged(_:))
        fillWell.target = self
        fillWell.action = #selector(fillWellChanged(_:))

        widthPopup.addItems(withTitles: Self.widths.map { "\($0.clean) pt" })
        widthPopup.target = self
        widthPopup.action = #selector(widthChanged(_:))
        fontPopup.addItems(withTitles: Self.fonts)
        for item in fontPopup.itemArray {
            if let font = NSFont(name: item.title, size: 13) {
                item.attributedTitle = NSAttributedString(string: item.title, attributes: [.font: font])
            }
        }
        fontPopup.target = self
        fontPopup.action = #selector(fontChanged(_:))
        sizePopup.addItems(withTitles: Self.sizes.map { "\($0.clean)" })
        sizePopup.target = self
        sizePopup.action = #selector(fontChanged(_:))

        colorRow = row("Colour", swatchRow(fill: false) + [colorWell])
        fillRow = row("Fill", swatchRow(fill: true) + [fillWell])
        widthRow = row("Line", [widthPopup])
        fontRow = row("Font", [fontPopup, sizePopup])

        let stack = NSStackView(views: [titleLabel, colorRow, fillRow, widthRow, fontRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        panel.contentView = content
    }

    private func row(_ title: String, _ views: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let row = NSStackView(views: [label] + views)
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func swatchRow(fill: Bool) -> [NSView] {
        var colors: [NSColor?] = Self.swatches
        if fill { colors.insert(nil, at: 0) }
        return colors.enumerated().map { index, color in
            let button = SwatchButton(color: color)
            button.target = self
            button.action = fill ? #selector(fillSwatch(_:)) : #selector(colorSwatch(_:))
            button.tag = index
            return button
        }
    }

    // MARK: State

    /// Shows the selected annotation's style, else the defaults for the
    /// armed tool, and only the controls that apply.
    func refresh() {
        guard panel.isVisible || panel.contentView != nil else { return }
        let target = feature.styleTarget
        titleLabel.stringValue = target.title.uppercased()
        colorWell.color = target.color
        fillWell.color = target.fill ?? .clear
        selectClosest(widthPopup, Self.widths, target.lineWidth)
        fontPopup.selectItem(withTitle: target.font.familyName ?? target.font.fontName)
        if fontPopup.selectedItem == nil { fontPopup.selectItem(at: 0) }
        selectClosest(sizePopup, Self.sizes, target.font.pointSize)
        fillRow.isHidden = !target.hasFill
        widthRow.isHidden = !target.hasLine
        fontRow.isHidden = !target.hasFont
    }

    private func selectClosest(_ popup: NSPopUpButton, _ values: [CGFloat], _ value: CGFloat) {
        let index = values.indices.min { abs(values[$0] - value) < abs(values[$1] - value) } ?? 0
        popup.selectItem(at: index)
    }

    // MARK: Actions

    @objc private func colorSwatch(_ sender: NSButton) { feature.setColor(Self.swatches[sender.tag]) }
    @objc private func fillSwatch(_ sender: NSButton) {
        feature.setFill(sender.tag == 0 ? nil : Self.swatches[sender.tag - 1])
    }
    @objc private func colorWellChanged(_ sender: NSColorWell) { feature.setColor(sender.color) }
    @objc private func fillWellChanged(_ sender: NSColorWell) { feature.setFill(sender.color) }
    @objc private func widthChanged(_ sender: NSPopUpButton) {
        feature.setLineWidth(Self.widths[max(0, sender.indexOfSelectedItem)])
    }
    @objc private func fontChanged(_ sender: NSPopUpButton) {
        feature.setFont(name: fontPopup.titleOfSelectedItem ?? "Helvetica",
                        size: Self.sizes[max(0, sizePopup.indexOfSelectedItem)])
    }
}

/// A round colour swatch; nil draws "no colour" (a slashed circle).
private final class SwatchButton: NSButton {
    let swatch: NSColor?

    init(color: NSColor?) {
        swatch = color
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 18).isActive = true
        toolTip = color == nil ? "None" : nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2))
        (swatch ?? .white).setFill()
        circle.fill()
        NSColor.separatorColor.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        if swatch == nil {
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: bounds.minX + 4, y: bounds.minY + 4))
            slash.line(to: NSPoint(x: bounds.maxX - 4, y: bounds.maxY - 4))
            NSColor.systemRed.setStroke()
            slash.lineWidth = 1.5
            slash.stroke()
        }
    }
}

private extension CGFloat {
    var clean: String { self == rounded() ? String(Int(self)) : String(describing: Double(self)) }
}

// MARK: - Style edits

/// What the inspector edits right now.
struct MarkupStyleTarget {
    var title: String
    var color: NSColor
    var fill: NSColor?
    var lineWidth: CGFloat
    var font: NSFont
    var hasFill: Bool
    var hasLine: Bool
    var hasFont: Bool
}

extension MarkupFeature {
    func toggleInspector() {
        if let inspector, inspector.isVisible {
            inspector.hide()
            return
        }
        let inspector = self.inspector ?? MarkupInspector(feature: self)
        self.inspector = inspector
        inspector.show(near: pdfView.window)
    }

    var styleTarget: MarkupStyleTarget {
        if let a = selected, let kind = MarkupKind(a) {
            let name: String = switch kind {
            case .textMarkup: (a.type ?? "Markup")
            case .note: "Note"
            case .textBox: "Text"
            case .shape: a.type == "Circle" ? "Oval" : "Rectangle"
            case .line: a.endLineStyle == .closedArrow || a.endLineStyle == .openArrow ? "Arrow" : "Line"
            case .ink: "Ink"
            }
            return MarkupStyleTarget(
                title: "Selected \(name)", color: kind == .textBox ? (a.fontColor ?? .black) : a.color,
                fill: a.interiorColor, lineWidth: a.border?.lineWidth ?? 1,
                font: a.font ?? style.font, hasFill: kind == .shape,
                hasLine: kind == .shape || kind == .line || kind == .ink, hasFont: kind == .textBox)
        }
        let t = tool
        return MarkupStyleTarget(
            title: t.map { "New \($0.rawValue)" } ?? "Defaults", color: style.color(for: t ?? .rectangle),
            fill: style.fillColor, lineWidth: style.lineWidth, font: style.font,
            hasFill: t == nil || t == .rectangle || t == .oval,
            hasLine: t == nil || [.rectangle, .oval, .line, .arrow, .ink].contains(t!),
            hasFont: t == nil || t == .text)
    }

    func setColor(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        if let a = selected, let kind = MarkupKind(a) {
            switch kind {
            case .textMarkup:
                switch a.type {
                case "Highlight": style.highlightColor = c
                case "Underline": style.underlineColor = c
                default: style.strikeColor = c
                }
            case .note: style.noteColor = c
            case .textBox: style.textColor = c
            default: style.strokeColor = c
            }
            change(a, name: "Change Colour") { a in
                if kind == .textBox {
                    a.fontColor = c
                } else {
                    a.color = c
                    if kind == .line, a.endLineStyle == .closedArrow { a.interiorColor = c }
                }
            }
            return
        }
        switch tool {
        case .highlight: style.highlightColor = c
        case .underline: style.underlineColor = c
        case .strikethrough: style.strikeColor = c
        case .note: style.noteColor = c
        case .text: style.textColor = c
        default: style.strokeColor = c
        }
        inspector?.refresh()
    }

    func setFill(_ color: NSColor?) {
        let c = color.flatMap { $0.alphaComponent < 0.01 ? nil : ($0.usingColorSpace(.sRGB) ?? $0) }
        style.fillColor = c
        if let a = selected, MarkupKind(a) == .shape {
            change(a, name: "Change Fill") { $0.interiorColor = c }
        } else {
            inspector?.refresh()
        }
    }

    func setLineWidth(_ width: CGFloat) {
        style.lineWidth = width
        guard let a = selected, let kind = MarkupKind(a), kind == .shape || kind == .line || kind == .ink else {
            inspector?.refresh()
            return
        }
        change(a, name: "Change Line Width") { a in
            let border = a.border ?? PDFBorder()
            border.lineWidth = width
            a.border = border
            if kind == .line {
                let (s, e) = MarkupFactory.lineEnds(a)
                MarkupFactory.setLine(a, from: s, to: e)
            }
            if kind == .ink {
                for path in a.paths ?? [] {
                    let copy = path.copy() as! NSBezierPath
                    copy.lineWidth = width
                    a.remove(path)
                    a.add(copy)
                }
            }
        }
    }

    func setFont(name: String, size: CGFloat) {
        style.fontName = name
        style.fontSize = size
        guard let a = selected, MarkupKind(a) == .textBox else {
            inspector?.refresh()
            return
        }
        let font = style.font
        change(a, name: "Change Font") { a in
            a.font = font
            // Keep the text visible: grow to at least one line.
            let line = ceil(font.ascender - font.descender + font.leading) + 8
            if a.bounds.height < line {
                var b = a.bounds
                b.origin.y = b.maxY - line
                b.size.height = line
                a.bounds = b
            }
        }
    }
}
