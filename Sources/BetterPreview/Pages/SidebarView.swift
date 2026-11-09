import AppKit
import BPCore
import PDFKit
import UniformTypeIdentifiers

/// The left sidebar of a PDF window: page thumbnails (with multi-select,
/// drag reorder, file drops and drag-out) or the table of contents.
///
/// Light by construction: NSTableView only makes views for visible rows,
/// thumbnails are rendered on demand off the main thread and kept in a
/// bounded cache, and nothing runs while the document is idle.
@MainActor
final class SidebarView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum Mode: Int { case thumbnails, outline }

    unowned let controller: PDFDocumentController
    unowned let host: DocumentWindowController
    weak var pages: PagesFeature?

    let cache = ThumbnailCache()
    let thumbnails = SidebarTableView()
    private let thumbnailScroll = NSScrollView()
    private(set) var outlineTable: NSTableView?
    private var outlineScroll: NSScrollView?
    private var header: NSSegmentedControl?
    private let handle = SidebarResizeHandle()
    private(set) var mode = Mode.thumbnails

    private var theme: Theme?
    private var currentPage = -1
    private var currentOutlineRow = -1
    /// The pages behind the selection, so it survives reorders and inserts.
    private var selectedPages: [PDFPage] = []
    private var isSelectingProgrammatically = false
    private var draggedRows = IndexSet()
    /// Thumbnail width the row heights were computed for.
    private var layoutWidth: CGFloat = 0
    private var pageSizes: [CGSize] = []

    init(controller: PDFDocumentController, window: DocumentWindowController) {
        self.controller = controller
        self.host = window
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 400))
        wantsLayer = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("page"))
        column.resizingMask = .autoresizingMask
        thumbnails.addTableColumn(column)
        configure(thumbnails)
        thumbnails.allowsMultipleSelection = true
        thumbnails.dataSource = self
        thumbnails.delegate = self
        thumbnails.target = self
        thumbnails.action = #selector(thumbnailClicked)
        thumbnails.onDelete = { [weak self] in self?.host.dispatch(ActionInvocation(.pageDelete)) }
        thumbnails.registerForDraggedTypes([.bpPageIndex, .fileURL])
        thumbnails.setDraggingSourceOperationMask(.move, forLocal: true)
        thumbnails.setDraggingSourceOperationMask(.copy, forLocal: false)
        thumbnails.draggingDestinationFeedbackStyle = .regular
        setUp(thumbnailScroll, with: thumbnails)
        addSubview(thumbnailScroll)

        handle.onDrag = { [weak self] x in self?.resize(to: x) }
        handle.onEnd = { [weak self] in self?.resizeEnded() }
        addSubview(handle)

        cache.isWanted = { [weak self] page in self?.isVisible(page) ?? false }
        cache.didRender = { [weak self] page, image in self?.show(image, for: page) }

        if !controller.outline.isEmpty {
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: "Thumbnails")!,
                NSImage(systemSymbolName: "list.bullet.indent", accessibilityDescription: "Contents")!,
            ], trackingMode: .selectOne, target: self, action: #selector(modeChanged))
            control.selectedSegment = 0
            control.segmentStyle = .automatic
            control.controlSize = .small
            control.refusesFirstResponder = true
            header = control
            addSubview(control)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(pagesDidChange),
                                               name: PagesFeature.pagesDidChange, object: controller)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func configure(_ table: NSTableView) {
        table.headerView = nil
        table.style = .plain
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.backgroundColor = .clear
    }

    private func setUp(_ scroll: NSScrollView, with table: NSTableView) {
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
    }

    override func layout() {
        super.layout()
        var top = bounds.height
        if let header {
            header.sizeToFit()
            let size = header.frame.size
            header.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(),
                                  y: top - (SidebarMetrics.headerHeight + size.height) / 2,
                                  width: size.width, height: size.height)
            top -= SidebarMetrics.headerHeight
        }
        let list = CGRect(x: 0, y: 0, width: bounds.width - 1, height: max(0, top))
        thumbnailScroll.frame = list
        outlineScroll?.frame = list
        handle.frame = CGRect(x: bounds.width - 5, y: 0, width: 5, height: bounds.height)
        updateRowHeightsIfNeeded()
    }

    // MARK: Appearance

    func apply(theme: Theme) {
        guard theme != self.theme else { return }
        self.theme = theme
        layer?.backgroundColor = theme.sidebarBg.cgColor
        handle.color = theme.completionHighlightBg.nsColor
        reloadVisibleThumbnailCells()
        outlineTable?.reloadData()
        markCurrentOutlineRow()
    }

    private var accent: NSColor { theme?.accent.nsColor ?? .controlAccentColor }
    private var textColor: NSColor { theme?.sidebarFg.nsColor ?? .secondaryLabelColor }
    private var paper: NSColor {
        controller.renderState.recolor != nil ? (theme?.recolorLightColor.nsColor ?? .white) : .white
    }

    // MARK: Show / hide

    func willShow() {
        reloadPages()
        documentStatusDidChange()
        if currentPage >= 0, currentPage < thumbnails.numberOfRows { reveal(currentPage, centered: true) }
    }

    func didHide() {
        cache.purge()
    }

    // MARK: Data

    private var document: PDFDocument? { controller.document }
    private var displayBox: PDFDisplayBox { controller.pdfView.displayBox }

    /// Recomputes page sizes and row heights and reloads everything.
    func reloadPages() {
        let box = displayBox
        if let document {
            pageSizes = (0..<document.pageCount).map { index in
                document.page(at: index).map { SidebarMetrics.pageSize($0, box: box) } ?? CGSize(width: 1, height: 1)
            }
        } else {
            pageSizes = []
        }
        layoutWidth = thumbnailScroll.frame.width
        thumbnails.reloadData()
        restoreSelection()
    }

    private func updateRowHeightsIfNeeded() {
        let width = thumbnailScroll.frame.width
        guard width > 0, abs(width - layoutWidth) >= 1 else { return }
        layoutWidth = width
        guard thumbnails.numberOfRows > 0 else { return }
        thumbnails.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<thumbnails.numberOfRows))
        for row in visibleRows { (thumbnails.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell)?
            .thumbSize = thumbSize(row: row) }
        // Heights changed, so the same offset shows other rows.
        if currentPage >= 0, currentPage < thumbnails.numberOfRows { reveal(currentPage, centered: true) }
    }

    private func thumbSize(row: Int) -> CGSize {
        let page = row < pageSizes.count ? pageSizes[row] : CGSize(width: 612, height: 792)
        return SidebarMetrics.thumbSize(width: layoutWidth, page: page)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === thumbnails ? pageSizes.count : controller.outline.count
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard tableView === thumbnails else { return SidebarMetrics.outlineRowHeight }
        return SidebarMetrics.rowHeight(thumbHeight: thumbSize(row: row).height)
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SidebarRowView()
        view.accent = accent
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView !== thumbnails { return outlineCell(row: row) }
        let cell = tableView.makeView(withIdentifier: ThumbnailCell.identifier, owner: nil) as? ThumbnailCell
            ?? ThumbnailCell(frame: .zero)
        configure(cell, row: row)
        return cell
    }

    private func configure(_ cell: ThumbnailCell, row: Int) {
        cell.thumbSize = thumbSize(row: row)
        cell.accent = accent
        cell.textColor = textColor
        cell.paper = paper
        cell.isCurrent = row == currentPage
        cell.label.stringValue = pageLabel(row)
        guard let page = document?.page(at: row) else { return }
        let (image, _) = cache.image(for: page, size: cell.thumbSize,
                                     scale: host.window?.backingScaleFactor ?? 2, box: displayBox)
        cell.image = image
    }

    /// The page label if the PDF defines one that differs, like Preview.
    private func pageLabel(_ row: Int) -> String {
        if let label = document?.page(at: row)?.label, !label.isEmpty, label != "\(row + 1)" {
            return "\(row + 1) (\(label))"
        }
        return "\(row + 1)"
    }

    private var visibleRows: Range<Int> {
        let range = thumbnails.rows(in: thumbnailScroll.contentView.bounds)
        return range.location..<(range.location + range.length)
    }

    /// Visible rows plus a couple either side (rendered just before they
    /// scroll in).
    private func isVisible(_ page: PDFPage) -> Bool {
        guard host.contentView.sidebarView === self, mode == .thumbnails,
              let document, page.document === document else { return false }
        let row = document.index(for: page)
        let rows = visibleRows
        return row >= rows.lowerBound - 2 && row < rows.upperBound + 2
    }

    private func show(_ image: NSImage, for page: PDFPage) {
        guard let document, page.document === document else { return }
        let row = document.index(for: page)
        guard row >= 0, row < thumbnails.numberOfRows else { return }
        (thumbnails.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell)?.image = image
    }

    private func reloadVisibleThumbnailCells() {
        for row in visibleRows {
            if let cell = thumbnails.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell {
                configure(cell, row: row)
            }
            (thumbnails.rowView(atRow: row, makeIfNecessary: false) as? SidebarRowView)?.accent = accent
        }
        thumbnails.enumerateAvailableRowViews { rowView, _ in
            (rowView as? SidebarRowView)?.accent = accent
            rowView.needsDisplay = true
        }
    }

    // MARK: Document changes

    private var renderKey: (Recolor?, Bool, Int, Int)?

    /// Follows the current page; re-renders when recolor, trim or the view
    /// rotation changed.
    func documentStatusDidChange() {
        let key = (controller.renderState.recolor, controller.isTrimmed, controller.viewRotation,
                   displayBox.rawValue)
        if let old = renderKey, old != key {
            cache.invalidateAll()
            let geometryChanged = old.1 != key.1 || old.2 != key.2
            if geometryChanged { reloadPages() } else { reloadVisibleThumbnailCells() }
        }
        renderKey = key
        setCurrentPage(controller.currentPageIndex)
    }

    @objc private func pagesDidChange() {
        // Sizes may change even when the count does not (rotation, reorder).
        reloadPages()
        currentPage = -1
        setCurrentPage(controller.currentPageIndex)
        if mode == .outline { outlineTable?.reloadData() }
    }

    private func setCurrentPage(_ index: Int) {
        guard index != currentPage else { return }
        let old = currentPage
        currentPage = index
        for row in [old, index] where row >= 0 && row < thumbnails.numberOfRows {
            (thumbnails.view(atColumn: 0, row: row, makeIfNecessary: false) as? ThumbnailCell)?.isCurrent = row == index
        }
        guard index >= 0, index < thumbnails.numberOfRows else { return }
        // A single selection follows the document; a multi-selection stays.
        if thumbnails.selectedRowIndexes.count <= 1, thumbnails.selectedRowIndexes != [index] {
            select(IndexSet(integer: index))
        }
        if mode == .thumbnails { reveal(index, centered: abs(index - old) > 1) }
        markCurrentOutlineRow()
    }

    /// Scrolls a row into view: minimally for neighbours, centred for jumps
    /// to a row that is not visible at all.
    private func reveal(_ row: Int, centered: Bool) {
        let rect = thumbnails.rect(ofRow: row)
        let clip = thumbnailScroll.contentView
        guard centered, !clip.bounds.intersects(rect) else { return thumbnails.scrollRowToVisible(row) }
        let maxY = max(0, thumbnails.frame.height - clip.bounds.height)
        let y = min(max(0, rect.midY - clip.bounds.height / 2), maxY)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: y))
        thumbnailScroll.reflectScrolledClipView(clip)
    }

    // MARK: Selection

    /// The selected pages, for page actions.
    var selection: IndexSet { thumbnails.selectedRowIndexes }

    func select(_ rows: IndexSet) {
        isSelectingProgrammatically = true
        thumbnails.selectRowIndexes(rows, byExtendingSelection: false)
        isSelectingProgrammatically = false
        rememberSelection()
    }

    private func rememberSelection() {
        selectedPages = thumbnails.selectedRowIndexes.compactMap { document?.page(at: $0) }
    }

    private func restoreSelection() {
        guard let document else { return }
        let rows = IndexSet(selectedPages.compactMap { page in
            page.document === document ? document.index(for: page) : nil
        })
        select(rows.isEmpty && currentPage >= 0 && currentPage < document.pageCount ? IndexSet(integer: currentPage) : rows)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSTableView) === thumbnails, !isSelectingProgrammatically else { return }
        rememberSelection()
    }

    /// A plain click on a thumbnail shows that page (and records a jump).
    @objc private func thumbnailClicked() {
        let row = thumbnails.clickedRow
        guard row >= 0, thumbnails.selectedRowIndexes == [row] else { return }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        guard flags.isDisjoint(with: [.command, .shift]) else { return }
        goToPage(row)
    }

    func goToPage(_ index: Int) {
        guard index != controller.currentPageIndex else { return }
        host.recordJump(from: controller.currentPosition)
        controller.show(pageAt: index, animated: false)
    }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard tableView === thumbnails, let pages else { return nil }
        let base = controller.fileURL.deletingPathExtension().lastPathComponent
        weak var page = document?.page(at: row)
        let promise = PageFilePromise(fileName: "\(base) - page \(row + 1).pdf") { [weak pages, weak self] in
            // The page may have moved since the drag began: find it again.
            guard let self, let pages, let page, let document, page.document === document else { return nil }
            return pages.pdfData(for: IndexSet(integer: document.index(for: page)))
        }
        let item = PageDragItem(fileType: UTType.pdf.identifier, delegate: promise)
        item.pageIndex = row
        item.page = page
        item.promise = promise
        return item
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        draggedRows = rowIndexes
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        draggedRows = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard tableView === thumbnails else { return [] }
        if dropOperation == .on { tableView.setDropRow(row, dropOperation: .above) }
        if info.draggingSource as? NSTableView === thumbnails, !draggedRows.isEmpty { return .move }
        return droppedFiles(info).isEmpty ? [] : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard tableView === thumbnails, let pages else { return false }
        if info.draggingSource as? NSTableView === thumbnails, !draggedRows.isEmpty {
            pages.movePages(draggedRows, to: row)
            return true
        }
        let files = droppedFiles(info)
        guard !files.isEmpty else { return false }
        return pages.insertFiles(files, at: row)
    }

    private func droppedFiles(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { url in
            guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
            return type.conforms(to: .pdf) || type.conforms(to: .image)
        }
    }

    // MARK: Resize

    private func resize(to x: CGFloat) {
        let width = min(max(x, SidebarMetrics.minWidth), SidebarMetrics.maxWidth)
        host.contentView.sidebarWidth = width.rounded()
    }

    private func resizeEnded() {
        cache.invalidateAll()
        reloadVisibleThumbnailCells()
    }

    // MARK: Outline

    @objc private func modeChanged() {
        setMode(Mode(rawValue: header?.selectedSegment ?? 0) ?? .thumbnails)
    }

    func setMode(_ new: Mode) {
        guard new != mode else { return }
        mode = new
        header?.selectedSegment = new.rawValue
        if new == .outline, outlineTable == nil { makeOutlineTable() }
        thumbnailScroll.isHidden = new != .thumbnails
        outlineScroll?.isHidden = new != .outline
        if new == .thumbnails {
            reloadVisibleThumbnailCells()
            if currentPage >= 0, currentPage < thumbnails.numberOfRows { reveal(currentPage, centered: true) }
        } else {
            outlineTable?.reloadData()
            currentOutlineRow = -1
            markCurrentOutlineRow()
        }
        needsLayout = true
    }

    private func makeOutlineTable() {
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")))
        configure(table)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(outlineClicked)
        table.refusesFirstResponder = true
        let scroll = NSScrollView()
        setUp(scroll, with: table)
        addSubview(scroll, positioned: .below, relativeTo: handle)
        outlineTable = table
        outlineScroll = scroll
    }

    private func outlineCell(row: Int) -> NSView {
        let cell = outlineTable?.makeView(withIdentifier: OutlineCell.identifier, owner: nil) as? OutlineCell
            ?? OutlineCell(frame: .zero)
        let entries = controller.outline
        guard row < entries.count else { return cell }
        cell.level = entries[row].level
        cell.label.stringValue = entries[row].title.isEmpty ? "(untitled)" : entries[row].title
        cell.label.textColor = theme?.sidebarFg.nsColor ?? .labelColor
        cell.label.toolTip = cell.label.stringValue
        return cell
    }

    @objc private func outlineClicked() {
        guard let table = outlineTable, table.clickedRow >= 0, table.clickedRow < controller.outline.count else { return }
        var position = controller.outline[table.clickedRow].position
        position.zoom = nil
        host.recordJump(from: controller.currentPosition)
        controller.go(to: position, animated: false)
    }

    /// Selects the last outline entry at or before the current page.
    private func markCurrentOutlineRow() {
        guard mode == .outline, let table = outlineTable else { return }
        let entries = controller.outline
        var row = -1
        for (index, entry) in entries.enumerated() where entry.position.page <= max(currentPage, 0) { row = index }
        guard row != currentOutlineRow else { return }
        currentOutlineRow = row
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
    }
}
