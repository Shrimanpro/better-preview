import AppKit
import BPCore

/// Views one image (all formats ImageIO decodes). Zoom is the scroll view's
/// magnification over a canvas sized in image pixels, so 100% is one image
/// pixel per point (two device pixels on a Retina screen).
@MainActor
final class ImageDocumentController: NSObject, DocumentController {
    let fileURL: URL
    weak var host: DocumentHost?
    let changes = ChangeTrackingUndoManager()
    var undoManager: UndoManager { changes }
    /// Dirty until undo/redo returns to the state last written to disk.
    var isDirty: Bool { changes.hasUnsavedChanges }
    /// Bitmap bytes held by each undo / redo step, oldest first (see +Edit).
    var undoCosts: [Int] = []
    var redoCosts: [Int] = []
    /// The original file's bytes once a save has overwritten it, so undo can
    /// still go back to (and edits start from) the original.
    var originalCopy: TemporaryCopy?
    /// Where the unedited original is read from.
    var originalURL: URL { originalCopy?.url ?? fileURL }

    var model: ImageModel
    var options = Options()
    var theme = Theme.fallbackDark
    /// Zero-based frame shown (or being decoded) for multi-frame files.
    var frameIndex = 0
    /// Edited bitmaps of frames other than the shown one (multi-frame files),
    /// so switching frames keeps unsaved edits; saved with every frame.
    var frameEdits: [Int: CGImage] = [:]
    /// The frame being decoded for a frame switch, until it is shown.
    var requestedFrame: Int?
    var fitMode = FitMode.page
    /// The default fit never enlarges past 100%; explicit fit commands do.
    var fitCapsAtOne = true
    /// Live crop rectangle while crop mode is on.
    var crop: CropOverlay?
    /// Floating adjust panel, created on first use.
    var adjustPanel: ImageAdjustPanel?
    /// Screen-sized copy of the image that adjust previews render from.
    var adjustProxy: CGImage?

    let scrollView = ImageScrollView()
    let canvas = ImageCanvasView()
    let scroller: SmoothScroller
    /// Longest side, in device pixels, of a downsample for huge images.
    let displayMax: Int
    var lastZoom: CGFloat = 0
    var statusPending = false
    var decodeGeneration = 0
    var isLoadingFull = false

    var view: NSView { scrollView }
    var preferredFirstResponder: NSView { canvas }

    init?(url: URL) {
        guard let info = ImageLoader.probe(url) else { return nil }
        fileURL = url
        model = ImageModel(info: info)
        scroller = SmoothScroller(scrollView: scrollView)
        displayMax = Int(NSScreen.screens.map { max($0.frame.width, $0.frame.height) * $0.backingScaleFactor }
            .max() ?? 3000)
        super.init()
        changes.onChange = { [weak self] in MainActor.assumeIsolated { self?.scheduleStatusUpdate() } }
        setUpViews()
        canvas.show(nil, pixelSize: model.pixelSize)
        decodeFrame(0, isInitial: true)
    }

    private func setUpViews() {
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onResize = { [weak self] in self?.viewResized() }
        canvas.onPan = { [weak self] delta in self?.pan(by: delta) }
        canvas.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipBoundsChanged), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(pinchEnded), name: NSScrollView.didEndLiveMagnifyNotification,
                           object: scrollView)
        applyAppearance()
    }

    // MARK: Options and theme

    func apply(options: Options, theme: Theme) {
        guard options != self.options || theme != self.theme else { return }
        self.options = options
        self.theme = theme
        applyAppearance()
    }

    private func applyAppearance() {
        scrollView.backgroundColor = theme.defaultBg.nsColor
        scrollView.drawsBackground = true
        scrollView.minMagnification = options.zoomMin
        scrollView.maxMagnification = options.zoomMax
        scroller.isEnabled = options.smoothScroll
        scroller.settleDuration = options.scrollDuration
    }

    // MARK: Status

    var status: DocumentStatus {
        let size = model.pixelSize
        var detail = "\(Int(size.width))×\(Int(size.height))"
        if model.frameCount > 1 { detail += " · \(model.frameCount) frames" }
        var flags: [String] = []
        if let crop {
            let r = crop.rect
            detail = "crop \(Int(r.width))×\(Int(r.height)) at \(Int(r.minX)),\(Int(r.minY))"
            flags.append("crop")
        }
        return DocumentStatus(
            page: frameIndex + 1, pageCount: model.frameCount, zoom: scrollView.magnification,
            flags: flags, detail: detail)
    }

    /// Coalesces bursts of changes (pinch, animation) into one notification.
    func scheduleStatusUpdate() {
        guard !statusPending else { return }
        statusPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            statusPending = false
            host?.documentStatusDidChange()
        }
    }

    // MARK: Decoding

    /// Decodes a frame off the main thread. Stale results are dropped.
    func decodeFrame(_ index: Int, isInitial: Bool = false, isReload: Bool = false) {
        decodeGeneration += 1
        let generation = decodeGeneration
        isLoadingFull = false
        // Frame switches read the original (edits live in `frameEdits`);
        // open and reload read the file.
        let url = isInitial || isReload ? fileURL : originalURL, displayMax = displayMax
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.load(url, index: index, displayMax: displayMax)
            }.value
            guard let self, generation == decodeGeneration else { return }
            finishDecode(loaded, index: index, isInitial: isInitial, isReload: isReload)
        }
    }

    private func finishDecode(_ loaded: ImageLoader.Loaded?, index: Int, isInitial: Bool, isReload: Bool) {
        guard let loaded else {
            if isInitial || isReload {
                host?.showMessage("Cannot read \(fileURL.lastPathComponent)", isError: true)
            }
            requestedFrame = nil
            return
        }
        let isFrameSwitch = !isInitial && !isReload
        requestedFrame = nil
        if isFrameSwitch {
            // Keep the shown frame's edit; bring back the new frame's.
            endInteractiveEdits()
            frameEdits[frameIndex] = model.pendingEdit
        } else {
            frameEdits.removeAll()
            discardEditState()
        }
        let edit = isFrameSwitch ? frameEdits.removeValue(forKey: index) : nil
        let sizeChanged = loaded.info.pixelSize != model.pixelSize
        model.sourceType = loaded.info.sourceType
        model.pixelSize = edit.map { CGSize(width: $0.width, height: $0.height) } ?? loaded.info.pixelSize
        model.dpi = loaded.info.dpi
        model.frameCount = loaded.info.frameCount
        model.image = loaded.image
        model.fullResolution = nil
        model.pendingEdit = edit
        frameIndex = index
        canvas.show(model.displayImage, pixelSize: model.pixelSize)
        if isInitial || (sizeChanged && fitMode != .none) {
            applyFit(resetScroll: isInitial || !isReload)
        }
        updateDetailLevel()
        scheduleStatusUpdate()
    }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        adjustPanel?.close()
    }

    func reloadFromDisk() {
        decodeFrame(frameIndex, isReload: true)
    }
}
