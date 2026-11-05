import AppKit
import BPCore
import PDFKit

/// Zoom, sticky fit modes, view rotation and layout modes.
extension PDFDocumentController {
    // MARK: Zoom

    /// Explicit zoom: ends the fit mode. PDFView keeps the content under the
    /// viewport centre in place when the scale changes.
    func setScale(_ scale: Double) {
        fitMode = .none
        setScaleKeepingFit(scale)
    }

    func zoom(by factor: Double) {
        setScale(pdfView.scaleFactor * factor)
    }

    func setScaleKeepingFit(_ scale: Double) {
        let clamped = min(max(scale, options.zoomMin), options.zoomMax)
        guard abs(clamped - pdfView.scaleFactor) > 1e-6 else { return }
        if let target = scroller.target { scroller.set(target) }  // zoom around where we were going
        isSettingScale = true
        pdfView.scaleFactor = clamped
        isSettingScale = false
    }

    // MARK: Fit

    func fit(_ mode: FitMode) {
        fitMode = mode
        let page = currentPageIndex
        applyFit(keepingPosition: true)
        if mode == .page {
            // Show the whole page, including its top margin.
            show(pageAt: page, animated: false)
            if let origin = scroller.destination {
                scroller.set(CGPoint(x: origin.x, y: origin.y - pdfView.pageBreakMargins.top))
            }
        }
    }

    /// Re-applies the sticky fit mode (after resize or a layout change).
    func applyFit(keepingPosition: Bool) {
        guard fitMode != .none, let scale = fitScale(fitMode),
              abs(scale - pdfView.scaleFactor) > 1e-4 else { return }
        let position = keepingPosition ? currentPosition : nil
        setScaleKeepingFit(scale)
        if let position {
            pdfView.layoutDocumentView()
            restore(position, animated: false)
        }
    }

    private func fitScale(_ mode: FitMode) -> Double? {
        guard let documentView, let page = pdfView.currentPage ?? document?.page(at: 0) else { return nil }
        var available = pdfView.bounds.size
        if let scrollView = scroller.scrollView, scrollView.scrollerStyle == .legacy {
            available.width -= NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        }
        let width = documentView.bounds.width
        guard available.width > 1, available.height > 1, width > 0 else { return nil }
        let widthFit = available.width / width
        guard mode == .page else { return widthFit }
        let margins = pdfView.pageBreakMargins
        let height = (documentRect(of: page)?.height ?? page.bounds(for: pdfView.displayBox).height)
            + margins.top + margins.bottom
        return min(widthFit, available.height / height)
    }

    // MARK: Layout

    func updateDisplayMode() {
        let mode: PDFDisplayMode = isContinuous
            ? (isDual ? .twoUpContinuous : .singlePageContinuous)
            : (isDual ? .twoUp : .singlePage)
        if pdfView.displayMode != mode { pdfView.displayMode = mode }
        let book = isDual && options.dualPageBook
        if pdfView.displaysAsBook != book { pdfView.displaysAsBook = book }
    }

    /// After dual/continuous/padding changes: relayout, refit, keep the page.
    func layoutDidChange() {
        let position = currentPosition
        scroller.stop()
        updateDisplayMode()
        pdfView.layoutDocumentView()
        applyFit(keepingPosition: false)
        pdfView.layoutDocumentView()
        restore(position, animated: false)
        scheduleStatusUpdate()
    }

    /// View rotation of all pages; keeps the current page's top in view.
    func rotateView(by degrees: Int) {
        guard let document else { return }
        let page = currentPosition.page
        scroller.stop()
        viewRotation = ((viewRotation + degrees) % 360 + 360) % 360
        Self.rotate(document, by: degrees)
        pdfView.layoutDocumentView()
        applyFit(keepingPosition: false)
        pdfView.layoutDocumentView()
        show(pageAt: page, animated: false)
        scheduleStatusUpdate()
    }

    static func rotate(_ document: PDFDocument, by degrees: Int) {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
    }
}
