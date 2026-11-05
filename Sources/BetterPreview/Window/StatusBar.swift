import AppKit
import BPCore

/// The strip at the bottom of a document window. Left: the file name or a
/// transient message. Right: pending keys, flags, search detail, zoom and
/// page. Draws its text directly; setting a property only redraws when the
/// value changed.
@MainActor
final class StatusBar: NSView {
    struct Message: Equatable {
        var text: String
        var isError: Bool
    }

    var fileName = "" { didSet { if fileName != oldValue { needsDisplay = true } } }
    var message: Message? { didSet { if message != oldValue { needsDisplay = true } } }
    /// Right-aligned fields, already formatted.
    var info: [String] = [] { didSet { if info != oldValue { needsDisplay = true } } }

    private var theme: Theme = .fallbackDark
    private var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { true }

    /// Height that fits `font` with some breathing room.
    static func height(for font: NSFont) -> CGFloat {
        max(22, lineHeight(font) + 8)
    }

    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    func apply(theme: Theme, font: NSFont) {
        guard theme != self.theme || font != self.font else { return }
        self.theme = theme
        self.font = font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = message.map { $0.isError ? theme.notificationErrorBg : theme.notificationBg } ?? theme.statusbarBg
        background.nsColor.setFill()
        bounds.fill()

        let inset: CGFloat = 8
        let rightText = info.filter { !$0.isEmpty }.joined(separator: "  ")
        let right = NSAttributedString(string: rightText, attributes: attributes(theme.statusbarFg, truncate: false))
        let rightWidth = ceil(right.size().width)
        let lineHeight = Self.lineHeight(font)
        let baseline = floor((bounds.height - lineHeight) / 2)
        right.draw(at: NSPoint(x: bounds.maxX - inset - rightWidth, y: baseline))

        let leftColor = message.map { $0.isError ? theme.notificationErrorFg : theme.notificationFg } ?? theme.statusbarFg
        let left = NSAttributedString(string: message?.text ?? fileName, attributes: attributes(leftColor, truncate: true))
        let leftRect = NSRect(x: inset, y: baseline, width: max(0, bounds.width - 3 * inset - rightWidth),
                              height: lineHeight)
        left.draw(with: leftRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func attributes(_ color: RGBA, truncate: Bool) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.nsColor]
        if truncate {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = style
        }
        return attributes
    }
}

extension NSFont {
    /// The UI font from `Options.font` / `fontSize`; system monospaced when
    /// the name is empty or unknown.
    static func bpUIFont(_ options: Options) -> NSFont {
        let size = CGFloat(options.fontSize)
        if !options.font.isEmpty, let font = NSFont(name: options.font, size: size) { return font }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}
