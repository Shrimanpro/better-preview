import AppKit
import BPCore

/// Minimal toolbar, built on first show. Every button dispatches an action
/// through the window, so keys, menus and the toolbar share one path.
@MainActor
final class ToolbarFeature: NSObject, WindowFeature, NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    unowned let window: DocumentWindowController
    private var toolbar: NSToolbar?
    private var shown = false
    private var lastOption: Bool?

    init(window: DocumentWindowController) {
        self.window = window
        super.init()
    }

    private struct Item {
        var id: String
        var label: String
        var symbol: String
        var name: ActionName
        var argument: String?
    }

    private static let sidebar = "bp.sidebar", share = "bp.share"
    private static let search = Item(id: "bp.search", label: "Search", symbol: "magnifyingglass", name: .searchForward)

    private static let items: [String: Item] = Dictionary(uniqueKeysWithValues: [
        Item(id: "bp.zoomOut", label: "Zoom Out", symbol: "minus.magnifyingglass", name: .zoomOut),
        Item(id: "bp.zoomIn", label: "Zoom In", symbol: "plus.magnifyingglass", name: .zoomIn),
        Item(id: "bp.fit", label: "Fit", symbol: "arrow.up.left.and.down.right.magnifyingglass", name: .fitPage),
        Item(id: "bp.rotate", label: "Rotate", symbol: "rotate.left", name: .rotateCCW),
        Item(id: "bp.highlight", label: "Highlight", symbol: "highlighter", name: .annotateHighlight),
        Item(id: "bp.note", label: "Note", symbol: "note.text", name: .toolNote),
        Item(id: "bp.text", label: "Text", symbol: "textformat", name: .toolText),
        Item(id: "bp.shapes", label: "Rectangle", symbol: "rectangle", name: .toolRectangle),
        Item(id: "bp.ink", label: "Draw", symbol: "pencil.tip", name: .toolInk),
        Item(id: "bp.sign", label: "Sign", symbol: "signature", name: .signaturePlace),
        Item(id: "bp.undo", label: "Undo", symbol: "arrow.uturn.backward", name: .undo),
        search,
    ].map { ($0.id, $0) })

    private var identifiers: [NSToolbarItem.Identifier] {
        let ids = [Self.sidebar, "bp.zoomOut", "bp.zoomIn", "bp.rotate", "bp.highlight", "bp.note", "bp.text",
                   "bp.shapes", "bp.ink", "bp.sign", Self.share, "bp.search"]
        var result = ids.map { NSToolbarItem.Identifier($0) }
        if let i = result.firstIndex(of: .init(Self.share)) { result.insert(.flexibleSpace, at: i) }
        return result
    }

    // MARK: WindowFeature

    func handle(_ invocation: ActionInvocation, in window: DocumentWindowController) -> Bool {
        guard invocation.action.name == .toggleToolbar else { return false }
        setShown(!shown)
        return true
    }

    func environmentDidChange(options: Options, theme: Theme) {
        guard options.toolbar != lastOption else { return }
        lastOption = options.toolbar
        setShown(options.toolbar)
    }

    private func setShown(_ visible: Bool) {
        guard visible != shown || (visible && toolbar == nil) else { return }
        shown = visible
        guard let nswindow = window.window else { return }
        if visible {
            if toolbar == nil {
                let created = NSToolbar(identifier: "BetterPreview.toolbar")
                created.delegate = self
                created.displayMode = .iconOnly
                created.allowsUserCustomization = false
                toolbar = created
            }
            nswindow.toolbarStyle = .unified
            nswindow.toolbar = toolbar
        } else {
            nswindow.toolbar = nil
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let id = identifier.rawValue
        if id == Self.share {
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.delegate = self
            item.label = "Share"
            item.toolTip = "Share"
            return item
        }
        let spec = id == Self.sidebar
            ? Item(id: id, label: "Sidebar", symbol: "sidebar.left", name: .toggleSidebar)
            : Self.items[id]
        guard let spec else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = spec.label
        item.toolTip = spec.label
        item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
        item.target = self
        item.action = #selector(clicked(_:))
        item.isBordered = true
        return item
    }

    @objc private func clicked(_ sender: NSToolbarItem) {
        let id = sender.itemIdentifier.rawValue
        let spec = id == Self.sidebar ? Item(id: id, label: "", symbol: "", name: .toggleSidebar) : Self.items[id]
        guard let spec else { return }
        window.dispatch(ActionInvocation(spec.name, spec.argument))
    }

    func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        [window.content.fileURL]
    }
}
