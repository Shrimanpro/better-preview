import AppKit
import BPCore

/// Resolved colours and fonts for one palette instance.
struct PaletteStyle {
    let font: NSFont
    let boldFont: NSFont
    let fg: NSColor
    let dim: NSColor
    let selectedBg: NSColor
    let selectedFg: NSColor
    let accent: NSColor
    let rowHeight: CGFloat

    init(theme: Theme, options: Options) {
        let size = CGFloat(options.fontSize)
        let base = (options.font.isEmpty ? nil : NSFont(name: options.font, size: size))
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        font = base
        boldFont = NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask)
        fg = theme.completionFg.nsColor
        dim = theme.completionFg.nsColor.withAlphaComponent(0.55)
        selectedBg = theme.completionHighlightBg.nsColor
        selectedFg = theme.completionHighlightFg.nsColor
        accent = theme.accent.nsColor
        rowHeight = (size * 2.1).rounded()
    }
}

/// Borderless panel that can take key status and routes key events to the palette first.
final class PalettePanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

/// Table that never takes focus and reports hover and clicks.
final class PaletteTable: NSTableView {
    var onHover: ((Int) -> Void)?
    var onClick: ((Int) -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onHover?(row) }
    }

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0 { onClick?(row) }
    }
}

/// One reusable result row.
final class PaletteCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("PaletteCell")
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tagLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        label.lineBreakMode = .byTruncatingMiddle
        tagLabel.alignment = .right
        [icon, label, tagLabel].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height
        icon.frame = NSRect(x: 12, y: (h - 16) / 2, width: 16, height: 16)
        let tagWidth = tagLabel.stringValue.isEmpty ? 0 : ceil(tagLabel.attributedStringValue.size().width) + 4
        tagLabel.frame = NSRect(x: bounds.width - 12 - tagWidth, y: (h - 16) / 2, width: tagWidth, height: 16)
        let left: CGFloat = 36
        label.frame = NSRect(x: left, y: (h - 16) / 2, width: max(0, tagLabel.frame.minX - left - 8), height: 16)
    }

    func apply(_ result: PaletteResult, selected: Bool, style: PaletteStyle) {
        let item = result.item
        layer?.backgroundColor = selected ? style.selectedBg.cgColor : nil
        let fg = selected ? style.selectedFg : style.fg
        let symbol = switch item.kind {
        case .heading: "list.bullet"
        case .recent, .file: (item.url?.pathExtension.lowercased() == "pdf") ? "doc" : "photo"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = selected ? style.selectedFg : style.dim
        label.attributedStringValue = Self.title(result, selected: selected, style: style, fg: fg)
        tagLabel.attributedStringValue = NSAttributedString(string: Self.tagText(item), attributes: [
            .font: NSFont.systemFont(ofSize: style.font.pointSize - 1), .foregroundColor: style.dim])
        needsLayout = true
    }

    private static func tagText(_ item: PaletteItem) -> String {
        switch item.kind {
        case .recent: "recent"
        case .heading: "p.\((item.entry?.position.page ?? 0) + 1)"
        case .file: ""
        }
    }

    private static func title(_ result: PaletteResult, selected: Bool, style: PaletteStyle,
                              fg: NSColor) -> NSAttributedString {
        let item = result.item
        let text = item.display
        let out = NSMutableAttributedString(string: text, attributes: [.font: style.font, .foregroundColor: fg])
        let shift = item.indent
        func range(_ from: Int, _ count: Int) -> NSRange {
            let start = text.index(text.startIndex, offsetBy: from)
            return NSRange(start..<text.index(start, offsetBy: count), in: text)
        }
        if item.kind != .heading {
            let dir = shift + item.dirLength
            if item.dirLength > 0 {
                out.addAttribute(.foregroundColor, value: selected ? fg.withAlphaComponent(0.7) : style.dim,
                                 range: range(0, dir))
            }
            out.addAttribute(.font, value: style.boldFont, range: range(dir, text.count - dir))
        }
        for p in result.positions {
            let r = range(p + shift, 1)
            if selected {
                out.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue,
                                   .foregroundColor: fg], range: r)
            } else {
                out.addAttribute(.foregroundColor, value: style.accent, range: r)
            }
        }
        return out
    }
}
