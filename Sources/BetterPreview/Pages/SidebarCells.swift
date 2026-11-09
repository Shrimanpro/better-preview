import AppKit
import PDFKit

/// Geometry of a thumbnail row.
enum SidebarMetrics {
    static let inset: CGFloat = 14
    static let top: CGFloat = 8
    static let gap: CGFloat = 3
    static let labelHeight: CGFloat = 15
    static let bottom: CGFloat = 5
    static let outlineRowHeight: CGFloat = 22
    static let headerHeight: CGFloat = 30
    static let minWidth: CGFloat = 90
    static let maxWidth: CGFloat = 600

    /// The page's displayed size (rotation applied).
    static func pageSize(_ page: PDFPage, box: PDFDisplayBox) -> CGSize {
        let size = page.bounds(for: box).size
        return page.rotation % 180 == 0 ? size : CGSize(width: size.height, height: size.width)
    }

    /// Thumbnail size in points for a sidebar `width`: fills the width, very
    /// tall pages are capped so a row never gets absurdly high.
    static func thumbSize(width: CGFloat, page: CGSize) -> CGSize {
        let available = max(20, width - 2 * inset)
        let aspect = page.height / max(page.width, 1)
        let height = min(available * aspect, available * 1.6)
        let fittedWidth = min(available, height / max(aspect, 0.01))
        return CGSize(width: fittedWidth.rounded(), height: height.rounded())
    }

    static func rowHeight(thumbHeight: CGFloat) -> CGFloat {
        top + thumbHeight + gap + labelHeight + bottom
    }
}

/// One thumbnail: the page bitmap in a layer, with the page number below.
/// The current page gets an accent border and an accent label.
final class ThumbnailCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("thumbnail")

    private let thumb = CALayer()
    let label = NSTextField(labelWithString: "")
    var thumbSize = CGSize(width: 10, height: 10) { didSet { if thumbSize != oldValue { needsLayout = true } } }
    var isCurrent = false { didSet { if isCurrent != oldValue { updateMarker() } } }
    var accent = NSColor.controlAccentColor { didSet { updateMarker() } }
    var textColor = NSColor.secondaryLabelColor { didSet { updateMarker() } }
    /// Shown until the bitmap arrives: the paper color.
    var paper = NSColor.white { didSet { thumb.backgroundColor = paper.cgColor } }

    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            thumb.contents = image
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        thumb.contentsGravity = .resize
        thumb.backgroundColor = paper.cgColor
        thumb.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                         "borderColor": NSNull(), "borderWidth": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(thumb)
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override func layout() {
        super.layout()
        let x = ((bounds.width - thumbSize.width) / 2).rounded()
        thumb.frame = CGRect(x: x, y: SidebarMetrics.top, width: thumbSize.width, height: thumbSize.height)
        label.frame = CGRect(x: 0, y: SidebarMetrics.top + thumbSize.height + SidebarMetrics.gap,
                             width: bounds.width, height: SidebarMetrics.labelHeight)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        thumb.contentsScale = window?.backingScaleFactor ?? 2
    }

    private func updateMarker() {
        thumb.borderWidth = isCurrent ? 2 : 0.5
        thumb.borderColor = (isCurrent ? accent : textColor.withAlphaComponent(0.35)).cgColor
        label.textColor = isCurrent ? accent : textColor
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: isCurrent ? .semibold : .regular)
    }
}

/// A table-of-contents row: the title, indented by level.
final class OutlineCell: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("outline")
    let label = NSTextField(labelWithString: "")
    var level = 0 { didSet { if level != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 12)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let x = 10 + CGFloat(min(level, 8)) * 12
        let height = label.intrinsicContentSize.height
        label.frame = CGRect(x: x, y: ((bounds.height - height) / 2).rounded(),
                             width: max(0, bounds.width - x - 8), height: height)
    }
}

/// Row background: a rounded accent fill for selected rows.
final class SidebarRowView: NSTableRowView {
    var accent = NSColor.controlAccentColor

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        accent.withAlphaComponent(0.28).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

/// The thumbnail table: takes Delete / Forward Delete for the selected pages
/// (all other keys reach the window's key router first).
final class SidebarTableView: NSTableView {
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if let onDelete, event.keyCode == 51 || event.keyCode == 117 {
            onDelete()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// The thin vertical edge that resizes the sidebar.
final class SidebarResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    var color = NSColor.separatorColor { didSet { needsDisplay = true } }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let superview = superview?.superview else { return }
        onDrag?(superview.convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) { onEnd?() }
}

// MARK: - Dragging pages

extension NSPasteboard.PasteboardType {
    static let bpPageIndex = NSPasteboard.PasteboardType("org.betterpreview.page-index")
}

/// Writes one dragged page as a PDF file when dropped in Finder; the data
/// is only made if the drop actually asks for the file.
final class PageFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let fileName: String
    let makeData: @MainActor () -> Data?

    init(fileName: String, makeData: @escaping @MainActor () -> Data?) {
        self.fileName = fileName
        self.makeData = makeData
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { .main }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            guard let data = makeData() else { return completionHandler(CocoaError(.fileWriteUnknown)) }
            do {
                try data.write(to: url, options: .atomic)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

/// A dragged thumbnail: its page index for reordering inside the sidebar,
/// and a file promise for Finder.
final class PageDragItem: NSFilePromiseProvider {
    var pageIndex = 0
    weak var page: PDFPage?
    /// The provider holds its delegate weakly.
    var promise: PageFilePromise?

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [.bpPageIndex]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == .bpPageIndex ? pageIndex : super.pasteboardPropertyList(forType: type)
    }
}
