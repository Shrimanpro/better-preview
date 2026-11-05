import AppKit
import BPCore

/// Completion candidates shown above the input bar: at most `maxRows` rows,
/// scrolled so the selected row stays visible. Draws its rows directly.
@MainActor
final class CompletionList: NSView {
    static let maxRows = 10

    private var items: [String] = []
    private var selected: Int?
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

    var rowHeight: CGFloat { ceil(font.ascender - font.descender + font.leading) + 4 }

    /// Height needed for the current items.
    var preferredHeight: CGFloat { CGFloat(min(items.count, Self.maxRows)) * rowHeight }

    func show(_ items: [String], selected: Int?, theme: Theme, font: NSFont) {
        self.items = items
        self.selected = selected
        self.theme = theme
        self.font = font
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        theme.completionBg.nsColor.setFill()
        bounds.fill()
        let rows = min(items.count, Self.maxRows)
        guard rows > 0 else { return }
        let first = min(max(0, (selected ?? 0) - rows + 1), items.count - rows)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        for row in 0..<rows {
            let index = first + row
            let isSelected = index == selected
            // Row 0 is at the top.
            let rect = NSRect(x: 0, y: bounds.maxY - CGFloat(row + 1) * rowHeight, width: bounds.width, height: rowHeight)
            if isSelected {
                theme.completionHighlightBg.nsColor.setFill()
                rect.fill()
            }
            let color = isSelected ? theme.completionHighlightFg : theme.completionFg
            let text = NSAttributedString(string: items[index], attributes: [
                .font: font, .foregroundColor: color.nsColor, .paragraphStyle: style,
            ])
            text.draw(with: rect.insetBy(dx: 8, dy: 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
