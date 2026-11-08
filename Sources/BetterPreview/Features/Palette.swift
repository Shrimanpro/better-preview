import AppKit
import BPCore

/// The quick-open palette (fuzzy opener): recents, files under a directory and
/// outline headings in one ranked list.
@MainActor
enum Palette {
    private static var current: PaletteController?
    private static var testPending = ProcessInfo.processInfo.environment["BP_PALETTE_TEST"]

    /// Shows the palette as a floating panel centred near the top of `window`.
    /// Calls exactly one of the callbacks, or neither if dismissed with Esc.
    static func present(over window: NSWindow, theme: Theme, options: Options,
                        directory: URL, outline: [OutlineEntry],
                        onOpen: @escaping (URL) -> Void,
                        onJump: @escaping (OutlineEntry) -> Void) {
        if let current {
            current.focus()
            return
        }
        let controller = PaletteController(
            window: window, theme: theme, options: options, directory: directory, outline: outline,
            onOpen: onOpen, onJump: onJump)
        controller.onClose = { current = nil }
        current = controller
        controller.show()
        if let query = testPending {
            testPending = nil
            controller.runScriptedTest(query: query)
        }
    }
}

@MainActor
final class PaletteController: NSObject {
    var onClose: (() -> Void)?

    private let parent: NSWindow
    private let directory: URL
    private let style: PaletteStyle
    private let theme: Theme
    private let model: PaletteModel
    private let onOpen: (URL) -> Void
    private let onJump: (OutlineEntry) -> Void
    private let panel: PalettePanel
    private let field = NSTextField()
    private let separator = NSView()
    private let fieldBar = NSView()
    private let scroll = NSScrollView()
    private let table = PaletteTable()
    private let scanner = PaletteScanner()
    private weak var previousResponder: NSResponder?
    private var results: [PaletteResult] = []
    private var selected = 0
    private var scanned: [URL] = []
    private var scanDone = false
    private var scriptedQuery: String?
    private var resignObserver: NSObjectProtocol?
    private var closed = false

    private static let maxRows = 12

    init(window: NSWindow, theme: Theme, options: Options, directory: URL, outline: [OutlineEntry],
         onOpen: @escaping (URL) -> Void, onJump: @escaping (OutlineEntry) -> Void) {
        parent = window
        self.theme = theme
        self.directory = directory
        self.onOpen = onOpen
        self.onJump = onJump
        style = PaletteStyle(theme: theme, options: options)
        model = PaletteModel(directory: directory,
                             recentURLs: NSDocumentController.shared.recentDocumentURLs,
                             outline: outline)
        panel = PalettePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        super.init()
        buildViews()
    }

    // MARK: Lifecycle

    func show() {
        previousResponder = parent.firstResponder
        updatePanelFrame()
        parent.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.close() } }
        startScan()
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        scanner.cancel()
        resignObserver.map(NotificationCenter.default.removeObserver)
        parent.removeChildWindow(panel)
        panel.keyHandler = nil
        panel.orderOut(nil)
        parent.makeKey()
        parent.makeFirstResponder(previousResponder)
        table.dataSource = nil
        table.delegate = nil
        onClose?()
    }

    private func activate() {
        guard results.indices.contains(selected) else { return close() }
        let item = results[selected].item
        close()
        if let entry = item.entry { onJump(entry) } else if let url = item.url { onOpen(url) }
    }

    // MARK: Scanning

    private func startScan() {
        if let cached = PaletteCache.files(for: directory) {
            model.addFiles(cached)
            scanDone = true
            refresh()
            return
        }
        scanner.run(root: directory, batch: { [weak self] urls in
            Task { @MainActor in self?.received(urls) }
        }, done: { [weak self] completed in
            Task { @MainActor in self?.finished(completed) }
        })
        refresh()
    }

    private func received(_ urls: [URL]) {
        guard !closed else { return }
        scanned += urls
        model.addFiles(urls)
        refresh()
    }

    private func finished(_ completed: Bool) {
        guard !closed else { return }
        scanDone = true
        if completed { PaletteCache.store(scanned, for: directory) }
        scanned = []
        if let query = scriptedQuery { scriptedQuery = nil; runScriptedTest(query: query) }
    }

    // MARK: Results

    private func refresh() {
        results = model.results(for: field.stringValue)
        selected = 0
        table.reloadData()
        table.scrollRowToVisible(0)
        updatePanelFrame()
    }

    private func setQuery(_ text: String) {
        field.stringValue = text
        refresh()
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        select((selected + delta + results.count) % results.count, scroll: true)
    }

    private func select(_ row: Int, scroll: Bool) {
        guard row != selected, results.indices.contains(row) else { return }
        let old = selected
        selected = row
        table.reloadData(forRowIndexes: [old, row], columnIndexes: [0])
        if scroll { table.scrollRowToVisible(row) }
    }

    private func deleteWord() {
        var text = field.stringValue
        while text.last?.isWhitespace == true { text.removeLast() }
        while let last = text.last, !last.isWhitespace { text.removeLast() }
        setQuery(text)
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.control, .option, .command])
        if mods.isEmpty {
            switch event.keyCode {
            case 126: move(-1)
            case 125: move(1)
            case 36, 76: activate()
            case 53: close()
            default: return false
            }
            return true
        }
        guard mods == .control, let key = event.charactersIgnoringModifiers else { return false }
        switch key {
        case "n", "j": move(1)
        case "p", "k": move(-1)
        case "c", "[", "\u{1b}": close()
        case "u": setQuery("")
        case "w": deleteWord()
        default: return false
        }
        return true
    }

    // MARK: Layout

    private func buildViews() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        panel.keyHandler = { [weak self] event in MainActor.assumeIsolated { self?.handleKey(event) ?? false } }

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = theme.completionBg.cgColor
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = theme.completionFg.nsColor.withAlphaComponent(0.15).cgColor
        panel.contentView = content

        fieldBar.wantsLayer = true
        fieldBar.layer?.backgroundColor = theme.inputbarBg.cgColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = style.font
        field.textColor = theme.inputbarFg.nsColor
        field.placeholderAttributedString = NSAttributedString(
            string: "Open file, @ for headings", attributes: [.font: style.font, .foregroundColor: style.dim])
        field.delegate = self
        separator.wantsLayer = true
        separator.layer?.backgroundColor = theme.completionFg.nsColor.withAlphaComponent(0.15).cgColor

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.rowHeight = style.rowHeight
        table.dataSource = self
        table.delegate = self
        table.onHover = { [weak self] row in self?.select(row, scroll: false) }
        table.onClick = { [weak self] row in
            self?.select(row, scroll: false)
            self?.activate()
        }
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true

        fieldBar.addSubview(field)
        [fieldBar, separator, scroll].forEach(content.addSubview)
    }

    private var barHeight: CGFloat { (style.font.pointSize * 3).rounded() }

    private func updatePanelFrame() {
        let width = min(640, parent.frame.width - 40)
        let rows = min(results.count, Self.maxRows)
        let listHeight = CGFloat(rows) * style.rowHeight
        let height = barHeight + (rows > 0 ? 1 + listHeight : 0)
        let top = parent.frame.maxY - parent.frame.height * 0.2
        panel.setFrame(NSRect(x: parent.frame.midX - width / 2, y: top - height, width: width, height: height),
                       display: false)
        fieldBar.frame = NSRect(x: 0, y: height - barHeight, width: width, height: barHeight)
        let fieldHeight = ceil(style.font.pointSize * 1.6)
        field.frame = NSRect(x: 14, y: (barHeight - fieldHeight) / 2, width: width - 28, height: fieldHeight)
        separator.frame = NSRect(x: 0, y: listHeight, width: width, height: rows > 0 ? 1 : 0)
        scroll.frame = NSRect(x: 0, y: 0, width: width, height: listHeight)
        table.tableColumns[0].width = width
    }

    // MARK: Test hook

    /// Debug hook (`BP_PALETTE_TEST=<query>`): once the scan is done, applies the query, logs the top
    /// ten rows to stderr and simulates Return on the first one.
    func runScriptedTest(query: String) {
        guard scanDone else { scriptedQuery = query; return }
        setQuery(query)
        for (rank, result) in results.prefix(10).enumerated() {
            FileHandle.standardError.write(
                Data("PALETTE \(rank + 1) \(result.item.kind.rawValue) \(result.item.display)\n".utf8))
        }
        activate()
    }
}

extension PaletteController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) { refresh() }
}

extension PaletteController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: PaletteCell.identifier, owner: nil) as? PaletteCell
            ?? PaletteCell(frame: .zero)
        cell.apply(results[row], selected: row == selected, style: style)
        return cell
    }
}
