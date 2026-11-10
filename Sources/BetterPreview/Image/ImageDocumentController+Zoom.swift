import AppKit
import BPCore

/// Zoom, fit modes and level of detail.
extension ImageDocumentController {
    var zoom: CGFloat { scrollView.magnification }

    private var backingScale: CGFloat { view.window?.backingScaleFactor ?? 2 }

    /// Document-space centre of the viewport.
    private var viewportCenter: CGPoint {
        let bounds = scrollView.contentView.bounds
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Zooms around the viewport centre and drops any sticky fit.
    func setZoom(_ value: Double) {
        fitMode = .none
        applyZoom(value)
    }

    private func applyZoom(_ value: Double) {
        let clamped = min(max(value, options.zoomMin), options.zoomMax)
        scrollView.setMagnification(clamped, centeredAt: viewportCenter)
    }

    func zoom(byFactor factor: Double) {
        setZoom(zoom * factor)
    }

    /// Sets a sticky fit mode, as requested by the user.
    func fit(_ mode: FitMode) {
        fitMode = mode
        fitCapsAtOne = false
        applyFit(resetScroll: true)
    }

    /// Re-applies the current fit mode. `resetScroll` puts the top of the
    /// image (and its left edge, when wider than the view) at the corner.
    func applyFit(resetScroll: Bool) {
        let viewport = scrollView.contentSize
        let content = canvas.frame.size
        guard fitMode != .none, viewport.width > 0, viewport.height > 0, content.width > 0 else { return }
        var value = viewport.width / content.width
        if fitMode == .page { value = min(value, viewport.height / content.height) }
        if fitCapsAtOne { value = min(value, 1) }
        applyZoom(value)
        guard resetScroll else { return }
        let clip = scrollView.contentView
        let origin = clip.constrainBoundsRect(CGRect(origin: .zero, size: clip.bounds.size)).origin
        scroller.set(origin)
    }

    func viewResized() {
        applyFit(resetScroll: false)
    }

    // MARK: Zoom observation

    @objc func clipBoundsChanged() {
        let current = zoom
        guard current != lastZoom else { return }
        lastZoom = current
        updateDetailLevel()
        crop?.zoomChanged()
        scheduleStatusUpdate()
    }

    /// A pinch is a manual zoom: it ends the sticky fit.
    @objc func pinchEnded() {
        fitMode = .none
        scheduleStatusUpdate()
    }

    func pan(by delta: CGVector) {
        guard let origin = scroller.destination else { return }
        scroller.set(CGPoint(x: origin.x - delta.dx / zoom, y: origin.y - delta.dy / zoom))
    }

    // MARK: Level of detail

    /// Crisp pixels when zoomed in, and, for downsampled huge images, loads
    /// the full bitmap only once the downsample stops resolving and drops it
    /// again after zooming back out.
    func updateDetailLevel() {
        let devicePerPixel = zoom * backingScale
        canvas.setPixelated(zoom > 4)
        guard model.isDownsampled, let image = model.image, model.pendingEdit == nil else { return }
        let resolved = Double(image.width) / model.pixelSize.width
        if model.fullResolution == nil {
            if devicePerPixel > resolved * 1.25 { loadFullResolution() }
        } else if devicePerPixel < resolved * 0.8 {
            model.fullResolution = nil
            canvas.show(model.displayImage, pixelSize: model.pixelSize)
        }
    }

    private func loadFullResolution() {
        guard !isLoadingFull else { return }
        isLoadingFull = true
        let url = originalURL, index = frameIndex
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                ImageLoader.load(url, index: index, displayMax: 0, full: true)
            }.value
            guard let self, isLoadingFull, frameIndex == index else { return }
            isLoadingFull = false
            guard let loaded, loaded.info.pixelSize == model.pixelSize else { return }
            model.fullResolution = loaded.image
            canvas.show(model.displayImage, pixelSize: model.pixelSize)
            updateDetailLevel()
        }
    }
}
