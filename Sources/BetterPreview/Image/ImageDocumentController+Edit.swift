import AppKit
import BPCore
import ImageIO
import UniformTypeIdentifiers

/// Image editing: every edit replaces `model.pendingEdit` (the full-resolution
/// edited bitmap) through `setEdit`, which makes it undoable and tracks dirty.
///
/// Undo memory: rotate and flip undo by applying their inverse, so their steps
/// hold no bitmap; other steps hold the previous bitmap (none when it is the
/// decoded original). Once those bitmaps exceed `undoBudget`, the oldest undo
/// steps are dropped (the newest one is always kept).
extension ImageDocumentController {
    /// Bytes of bitmaps the undo stack may hold.
    static let undoBudget = 512 * 1024 * 1024

    /// A lossless edit and its inverse, applied to the current bitmap.
    struct Reversal {
        let forward: (CGImage) -> CGImage?
        let backward: (CGImage) -> CGImage?
        var reversed: Reversal { Reversal(forward: backward, backward: forward) }
    }

    /// Hard cap for resize results, in pixels per side and in total.
    private static let maxSide = 30000
    private static let maxPixels = 300_000_000

    // MARK: State

    /// Called when a fresh decode replaces the bitmap (open, reload, frame).
    func discardEditState() {
        endInteractiveEdits()
        changes.resetChanges()
        undoCosts.removeAll()
        redoCosts.removeAll()
        originalCopy = nil
    }

    /// Ends crop mode and closes the adjust panel (its preview is per frame).
    func endInteractiveEdits() {
        cancelCrop()
        adjustPanel?.close()
        adjustProxy = nil
    }

    /// The full-resolution bitmap edits start from.
    func workingBase() -> CGImage? {
        if let edited = model.pendingEdit { return edited }
        if let full = model.fullResolution { return full }
        if model.isDownsampled {
            return ImageLoader.load(originalURL, index: frameIndex, displayMax: 0, full: true)?.image
        }
        return model.image
    }

    /// Installs an edited bitmap (nil returns to the decoded original) and
    /// registers its inverse (undo and redo come back through here).
    /// With `reversal` (which turns the current bitmap into `image`), undo
    /// recomputes the previous bitmap instead of keeping it.
    func setEdit(_ image: CGImage?, size: CGSize, name: String, reversal: Reversal? = nil, frame: Int? = nil) {
        let frame = frame ?? frameIndex
        let onShown = frame == frameIndex
        let oldImage = onShown ? model.pendingEdit : frameEdits[frame]
        let oldSize = onShown ? model.pixelSize
            : oldImage.map { CGSize(width: $0.width, height: $0.height) }
                ?? ImageLoader.probe(originalURL, index: frame)?.pixelSize ?? size
        var cost = 0
        if let reversal, oldImage != nil, image != nil {
            let back = reversal.reversed
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    let edit = frame == target.frameIndex ? target.model.pendingEdit : target.frameEdits[frame]
                    guard let current = edit, let previous = back.forward(current) else {
                        target.host?.showMessage("\(name): cannot undo", isError: true)
                        return
                    }
                    target.setEdit(previous, size: oldSize, name: name, reversal: back, frame: frame)
                }
            }
        } else {
            cost = oldImage.map { $0.bytesPerRow * $0.height } ?? 0
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.setEdit(oldImage, size: oldSize, name: name, reversal: reversal?.reversed, frame: frame)
                }
            }
        }
        undoManager.setActionName(name)
        trackUndoCost(cost)
        guard onShown else {
            // Undo / redo of another frame's edit: change it there and show it.
            frameEdits[frame] = image
            showFrame(frame)
            return
        }
        if requestedFrame != nil {
            // An undo for the shown frame wins over a pending frame switch.
            requestedFrame = nil
            decodeGeneration += 1
        }
        model.pendingEdit = image
        model.pixelSize = size
        if image != nil { model.fullResolution = nil }
        canvas.show(model.displayImage, pixelSize: size)
        if fitMode != .none { applyFit(resetScroll: true) }
        updateDetailLevel()
        scheduleStatusUpdate()
    }

    /// Mirrors the undo and redo stacks' bitmap bytes and, after a new edit,
    /// drops the oldest undo steps beyond `undoBudget`.
    private func trackUndoCost(_ cost: Int) {
        if undoManager.isUndoing {
            _ = undoCosts.popLast()
            redoCosts.append(cost)
        } else if undoManager.isRedoing {
            _ = redoCosts.popLast()
            undoCosts.append(cost)
        } else {
            undoCosts.append(cost)
            redoCosts.removeAll()
            // The edit's undo group closes at the end of this event.
            DispatchQueue.main.async { [weak self] in self?.trimUndo() }
        }
    }

    func trimUndo() {
        guard undoManager.groupingLevel == 0, !undoManager.isUndoing, !undoManager.isRedoing else { return }
        var total = undoCosts.reduce(0, +) + redoCosts.reduce(0, +)
        var drop = 0
        while total > Self.undoBudget, undoCosts.count - drop > 1 {
            total -= undoCosts[drop]
            drop += 1
        }
        guard drop > 0 else { return }
        undoCosts.removeFirst(drop)
        // Lowering the limit discards the oldest groups; then lift it again.
        undoManager.levelsOfUndo = undoCosts.count
        undoManager.levelsOfUndo = 0
    }

    /// Bytes of bitmaps currently held for undo and redo (for the self-test).
    var undoBitmapBytes: Int { undoCosts.reduce(0, +) + redoCosts.reduce(0, +) }

    private func commit(_ image: CGImage?, name: String, reversal: Reversal? = nil) {
        guard let image else {
            host?.showMessage("\(name): failed", isError: true)
            return
        }
        setEdit(image, size: CGSize(width: image.width, height: image.height), name: name, reversal: reversal)
    }

    // MARK: Transforms

    func rotate(clockwise: Bool) {
        cancelCrop()
        guard let base = workingBase() else { return }
        let reversal = Reversal(forward: { ImageOps.rotate($0, clockwise: clockwise) },
                                backward: { ImageOps.rotate($0, clockwise: !clockwise) })
        commit(reversal.forward(base), name: clockwise ? "Rotate Right" : "Rotate Left", reversal: reversal)
    }

    func flip(horizontal: Bool) {
        cancelCrop()
        guard let base = workingBase() else { return }
        let flip: (CGImage) -> CGImage? = { ImageOps.flip($0, horizontal: horizontal) }
        commit(flip(base), name: horizontal ? "Flip Horizontal" : "Flip Vertical",
               reversal: Reversal(forward: flip, backward: flip))
    }

    // MARK: Crop

    func imageCrop(_ argument: String?) {
        if let argument, let rect = Self.parseRect(argument) {
            cancelCrop()
            return applyCrop(rect)
        }
        if let crop {
            applyCrop(crop.rect)
            return
        }
        guard let layer = canvas.layer else { return }
        adjustPanel?.close()
        let overlay = CropOverlay(canvasLayer: layer, imageSize: model.pixelSize, zoom: zoom)
        crop = overlay
        canvas.overlay = overlay
        host?.showMessage("Drag to select. Return crops, Esc cancels.", isError: false)
        scheduleStatusUpdate()
    }

    func cancelCrop() {
        guard let crop else { return }
        crop.remove()
        self.crop = nil
        canvas.overlay = nil
        scheduleStatusUpdate()
    }

    private func applyCrop(_ requested: CGRect) {
        cancelCrop()
        let bounds = CGRect(origin: .zero, size: model.pixelSize)
        let rect = requested.standardized.integral.intersection(bounds)
        guard rect.width >= 1, rect.height >= 1 else {
            host?.showMessage("crop: empty selection", isError: true)
            return
        }
        guard rect.size != model.pixelSize, let base = workingBase() else { return }
        commit(ImageOps.crop(base, to: rect), name: "Crop")
    }

    /// "x,y,w,h" in pixels, top-left origin.
    private static func parseRect(_ text: String) -> CGRect? {
        let numbers = text.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard numbers.count == 4 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard crop != nil else { return false }
        switch event.keyCode {
        case 36, 76: // return, enter
            imageCrop(nil)
            return true
        case 53: // escape
            cancelCrop()
            return true
        default:
            return false
        }
    }

    // MARK: Resize

    /// "800x600", "800x", "x600" or "50%"; no argument shows the sheet.
    func imageResize(_ argument: String?) {
        cancelCrop()
        let size = model.pixelSize
        guard let argument, !argument.isEmpty else { return showResizeSheet() }
        let text = argument.lowercased().trimmingCharacters(in: .whitespaces)
        var target: (Int, Int)?
        if text.hasSuffix("%"), let p = Double(text.dropLast()), p > 0 {
            target = (Int((size.width * p / 100).rounded()), Int((size.height * p / 100).rounded()))
        } else {
            let parts = text.split(separator: "x", omittingEmptySubsequences: false).map { Double($0) }
            if parts.count == 2 {
                switch (parts[0], parts[1]) {
                case let (w?, h?): target = (Int(w), Int(h))
                case let (w?, nil): target = (Int(w), Int((w * size.height / size.width).rounded()))
                case let (nil, h?): target = (Int((h * size.width / size.height).rounded()), Int(h))
                default: break
                }
            }
        }
        guard let (w, h) = target else {
            host?.showMessage("image-resize: use WxH, Wx, xH or N%", isError: true)
            return
        }
        applyResize(width: w, height: h)
    }

    private func applyResize(width: Int, height: Int) {
        guard width > 0, height > 0, width <= Self.maxSide, height <= Self.maxSide,
              width * height <= Self.maxPixels else {
            host?.showMessage("image-resize: size out of range", isError: true)
            return
        }
        guard width != Int(model.pixelSize.width) || height != Int(model.pixelSize.height),
              let base = workingBase() else { return }
        commit(ImageOps.resize(base, width: width, height: height), name: "Resize")
    }

    private func showResizeSheet() {
        let form = ResizeForm(size: model.pixelSize)
        let alert = NSAlert()
        alert.messageText = "Resize Image"
        alert.informativeText = "Current size: \(Int(model.pixelSize.width)) × \(Int(model.pixelSize.height)) px"
        alert.accessoryView = form.view
        alert.addButton(withTitle: "Resize")
        alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let (w, h) = form.result else { return }
            self?.applyResize(width: w, height: h)
        }
        if let window = view.window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { finish(response) }
            }
        } else {
            finish(alert.runModal())
        }
    }

    // MARK: Adjust

    func imageAdjust(_ argument: String?) {
        cancelCrop()
        if let argument, !argument.isEmpty {
            guard let adjustments = ImageAdjustments.parse(argument) else {
                host?.showMessage("image-adjust: use \(ImageAdjustments.sliders.map { $0.key + "=N" }.joined(separator: " "))",
                                  isError: true)
                return
            }
            return applyAdjustments(adjustments)
        }
        guard let source = model.pendingEdit ?? model.fullResolution ?? model.image else { return }
        let longest = CGFloat(max(source.width, source.height))
        let scale = min(1, 1600 / longest)
        adjustProxy = scale < 1
            ? ImageOps.resize(source, width: max(1, Int(CGFloat(source.width) * scale)),
                              height: max(1, Int(CGFloat(source.height) * scale)))
            : source
        let panel = adjustPanel ?? ImageAdjustPanel()
        adjustPanel = panel
        panel.set(ImageAdjustments())
        panel.reopen()
        panel.onChange = { [weak self] values in self?.previewAdjustments(values) }
        panel.onApply = { [weak self] values in self?.finishAdjust(apply: values) }
        panel.onCancel = { [weak self] in self?.finishAdjust(apply: nil) }
        if let window = view.window {
            // The panel is a separate window: close it with the document's.
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(documentWindowWillClose(_:)),
                                                   name: NSWindow.willCloseNotification, object: window)
        }
        if let frame = view.window?.frame {
            panel.setFrameTopLeftPoint(CGPoint(x: frame.maxX - panel.frame.width - 16, y: frame.maxY - 60))
        }
        panel.orderFront(nil)
    }

    /// Closes and releases the adjust panel when the document window closes.
    @objc func documentWindowWillClose(_ note: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        releaseAdjustPanel()
    }

    func releaseAdjustPanel() {
        guard let panel = adjustPanel else { return }
        panel.onChange = nil
        panel.onApply = nil
        panel.onCancel = nil
        panel.close()
        adjustPanel = nil
        adjustProxy = nil
    }

    private func previewAdjustments(_ values: ImageAdjustments) {
        guard let proxy = adjustProxy, let image = ImageAdjustEngine.render(proxy, values) else { return }
        canvas.show(image, pixelSize: model.pixelSize)
    }

    private func finishAdjust(apply values: ImageAdjustments?) {
        adjustProxy = nil
        canvas.show(model.displayImage, pixelSize: model.pixelSize)
        if let values { applyAdjustments(values) }
    }

    private func applyAdjustments(_ values: ImageAdjustments) {
        guard !values.isIdentity else { return }
        // Unedited single-frame images are read from the file by Core Image
        // (no full decode of our own); edited ones from the edit bitmap.
        let file = model.pendingEdit == nil && model.frameCount <= 1 ? originalURL : nil
        commit(ImageAdjustEngine.renderFull(file: file, size: model.pixelSize, fallback: { workingBase() }, values),
               name: "Adjust Color")
    }

    // MARK: Save and export

    func save(to url: URL?) throws {
        cancelCrop()
        let target = url ?? fileURL
        let inPlace = target.standardizedFileURL == fileURL.standardizedFileURL
        if inPlace, !isDirty { return }
        // Undo can still return to the original after the file is
        // overwritten: keep the original file's bytes in a temporary copy.
        var copy: TemporaryCopy?
        if inPlace, originalCopy == nil {
            copy = TemporaryCopy(of: fileURL)
        }
        try write(to: target, type: nil, quality: 0.92)
        if inPlace {
            if let copy { originalCopy = copy }
            changes.markSaved()
        }
    }

    /// Encodes the current bitmap. `type` defaults to the target's extension.
    func write(to target: URL, type requested: UTType?, quality: Double) throws {
        guard let type = requested ?? ImageEncoder.type(for: target) else {
            throw ImageEncoder.Failure(errorDescription: "Unknown image format .\(target.pathExtension)")
        }
        guard let image = workingBase() else {
            throw ImageEncoder.Failure(errorDescription: "No image to save")
        }
        var metadata: [CFString: Any] = [:]
        if let source = ImageLoader.source(originalURL),
           let props = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any] {
            metadata = props
        }
        try ImageEncoder.write(image, to: target, type: type, quality: quality, dpi: model.dpi, metadata: metadata,
                               frames: frameSet(for: type))
    }

    /// `export [path] [quality] [force]`: with a path (quoted if it has
    /// spaces), converts by its extension, refusing to replace an existing
    /// file unless `force` is given, and never the open file; without, shows
    /// a panel with format and quality.
    func export(_ argument: String?) {
        cancelCrop()
        var words = CommandParser.splitArgumentWords(argument ?? "")
        var quality = 0.9
        var force = false
        if let last = words.last, !last.quoted, ["force", "!"].contains(last.text.lowercased()) {
            force = true
            words.removeLast()
        }
        if words.count > 1, let last = words.last, !last.quoted, let q = Double(last.text), (1...100).contains(q) {
            quality = q / 100
            words.removeLast()
        }
        if !words.isEmpty {
            guard words.count == 1 || !words.contains(where: \.quoted) else {
                host?.showMessage("export: unexpected '\(words[1].text)' (export [path] [quality] [force])",
                                  isError: true)
                return
            }
            let path = words.map(\.text).joined(separator: " ")
            let expanded = (path as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                : fileURL.deletingLastPathComponent().appendingPathComponent(expanded)).standardizedFileURL
            if url == fileURL.standardizedFileURL {
                host?.showMessage("export: that is the open file; use save", isError: true)
                return
            }
            if !force, FileManager.default.fileExists(atPath: url.path) {
                host?.showMessage("export: \(url.lastPathComponent) exists (add \"force\" to replace it)", isError: true)
                return
            }
            runExport(to: url, type: nil, quality: quality)
            return
        }
        let panel = NSSavePanel()
        panel.directoryURL = fileURL.deletingLastPathComponent()
        panel.nameFieldStringValue = fileURL.deletingPathExtension().lastPathComponent
        let accessory = ExportAccessory(panel: panel, initial: model.sourceType)
        panel.accessoryView = accessory.view
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.runExport(to: url, type: accessory.type, quality: accessory.quality)
        }
        if let window = view.window {
            panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { finish(response) } }
        } else {
            finish(panel.runModal())
        }
    }

    private func runExport(to url: URL, type: UTType?, quality: Double) {
        do {
            try write(to: url, type: type, quality: quality)
            host?.showMessage("exported \(url.path)", isError: false)
        } catch {
            host?.showMessage("export: \(error.localizedDescription)", isError: true)
        }
    }
}

/// A copy of a file in the temporary directory, deleted with this object.
final class TemporaryCopy {
    let url: URL

    init?(of source: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BetterPreview-originals", isDirectory: true)
        let url = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: url)
        } catch {
            return nil
        }
        self.url = url
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
