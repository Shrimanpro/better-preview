import AppKit
import UniformTypeIdentifiers

/// Smoothed freehand canvas. Always white paper with dark ink, like the
/// result will look on a page.
final class SignatureCanvas: NSView {
    private var strokes: [InkStroke] = []
    private var current: InkStroke?
    var onChange: (() -> Void)?
    static let lineWidth: CGFloat = 2.6

    override var isFlipped: Bool { false }
    var isEmpty: Bool { strokes.isEmpty && current == nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Baseline guide.
        ctx.setStrokeColor(NSColor(white: 0.8, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: 16, y: bounds.height * 0.3))
        ctx.addLine(to: CGPoint(x: bounds.width - 16, y: bounds.height * 0.3))
        ctx.strokePath()
        paintStrokes(in: ctx, color: NSColor(srgbRed: 14 / 255, green: 18 / 255, blue: 48 / 255, alpha: 1).cgColor, scale: 1)
    }

    private func paintStrokes(in ctx: CGContext, color: CGColor, scale: CGFloat) {
        ctx.setStrokeColor(color)
        ctx.setLineWidth(Self.lineWidth * scale)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        for stroke in strokes + (current.map { [$0] } ?? []) {
            if let path = stroke.path().copy(using: &transform) {
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        var stroke = InkStroke()
        stroke.add(convert(event.locationInWindow, from: nil), at: event.timestamp)
        current = stroke
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        current?.add(convert(event.locationInWindow, from: nil), at: event.timestamp)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let stroke = current { strokes.append(stroke) }
        current = nil
        needsDisplay = true
        onChange?()
    }

    func clear() {
        strokes.removeAll()
        current = nil
        needsDisplay = true
        onChange?()
    }

    /// The drawing as a transparent image (3x), cropped to the ink.
    func makeImage() -> CGImage? {
        let scale: CGFloat = 3
        let w = Int(bounds.width * scale), h = Int(bounds.height * scale)
        guard w > 0, h > 0, !strokes.isEmpty else { return nil }
        var coverage = [UInt8](repeating: 0, count: w * h)
        let ok = coverage.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            paintStrokes(in: ctx, color: CGColor(gray: 1, alpha: 1), scale: scale)
            return true
        }
        guard ok else { return nil }
        // The bitmap's row 0 is the top, which is what CGImage expects.
        return SignatureImaging.makeImage(alpha: coverage, width: w, height: h)
    }
}

/// The "Signatures" window: draw or import, list, delete, place.
@MainActor
final class SignatureManager: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static let shared = SignatureManager()

    private var window: NSWindow?
    private let canvas = SignatureCanvas()
    private let table = NSTableView()
    private var saveButton: NSButton!
    private var placeButton: NSButton!
    private var deleteButton: NSButton!
    private var entries: [SignatureStore.Entry] = []
    private weak var feature: FormsFeature?

    func show(for feature: FormsFeature) {
        self.feature = feature
        if window == nil { buildWindow() }
        reload()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Signatures"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let prompt = NSTextField(labelWithString: "Draw your signature with the trackpad or mouse")
        prompt.font = .systemFont(ofSize: 12)
        prompt.textColor = .secondaryLabelColor

        canvas.wantsLayer = true
        canvas.layer?.borderWidth = 1
        canvas.layer?.borderColor = NSColor.separatorColor.cgColor
        canvas.layer?.cornerRadius = 6
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.heightAnchor.constraint(equalToConstant: 170).isActive = true
        canvas.onChange = { [weak self] in self?.updateButtons() }

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearCanvas))
        saveButton = NSButton(title: "Save Drawing", target: self, action: #selector(saveDrawing))
        saveButton.keyEquivalent = "\r"
        let importButton = NSButton(title: "Import Image…", target: self, action: #selector(importImage))
        let drawRow = NSStackView(views: [clear, NSView(), importButton, saveButton])
        drawRow.distribution = .fill

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sig"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 56
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.doubleAction = #selector(placeSelected)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteSelected))
        placeButton = NSButton(title: "Place in Document", target: self, action: #selector(placeSelected))
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        let bottom = NSStackView(views: [deleteButton, NSView(), placeButton, done])
        bottom.distribution = .fill

        let stack = NSStackView(views: [prompt, canvas, drawRow, NSTextField(labelWithString: "Saved signatures"), scroll, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [canvas, drawRow, scroll, bottom] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        win.contentView = stack
        window = win
        updateButtons()
    }

    private func reload() {
        entries = SignatureStore.shared.list()
        table.reloadData()
        updateButtons()
    }

    private func updateButtons() {
        saveButton?.isEnabled = !canvas.isEmpty
        let has = table.selectedRow >= 0
        deleteButton?.isEnabled = has
        placeButton?.isEnabled = has && feature != nil
    }

    // MARK: Actions

    @objc private func clearCanvas() { canvas.clear() }

    @objc private func saveDrawing() {
        guard let image = canvas.makeImage() else { return }
        add(image)
        canvas.clear()
    }

    @objc private func importImage() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a picture of your signature on plain paper"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.importPicture(at: url) }
        }
    }

    func importPicture(at url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let image = SignatureImaging.fromPicture(picture) else {
            NSSound.beep()
            return
        }
        add(image)
    }

    private func add(_ image: CGImage) {
        do {
            let entry = try SignatureStore.shared.add(image)
            reload()
            if let row = entries.firstIndex(where: { $0.url == entry.url }) {
                table.selectRowIndexes([row], byExtendingSelection: false)
            }
        } catch {
            NSAlert(error: error).beginSheetModal(for: window!)
        }
    }

    @objc private func deleteSelected() {
        let row = table.selectedRow
        guard entries.indices.contains(row) else { return }
        SignatureStore.shared.delete(entries[row])
        reload()
    }

    @objc private func placeSelected() {
        let row = table.selectedRow
        guard entries.indices.contains(row), let feature else { return }
        window?.orderOut(nil)
        feature.place(entries[row])
        feature.pdfView.window?.makeKeyAndOrderFront(nil)
        feature.pdfView.window?.makeFirstResponder(feature.pdfView)
    }

    @objc private func closeWindow() { window?.orderOut(nil) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let cell = NSTableCellView()
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyUpOrDown
        if let cg = SignatureStore.shared.image(for: entry) {
            preview.image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.white.cgColor
        preview.layer?.cornerRadius = 4
        let label = NSTextField(labelWithString: entry.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(preview)
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            preview.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 140),
            preview.heightAnchor.constraint(equalToConstant: 44),
            label.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }
}
