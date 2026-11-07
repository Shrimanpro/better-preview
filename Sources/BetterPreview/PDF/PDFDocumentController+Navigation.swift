import AppKit
import BPCore
import PDFKit

/// Scrolling, page navigation and positions (marks, jump list, reload).
///
/// Geometry is done in the document view's coordinate space (the clip view's
/// bounds space): flipped, and independent of zoom.
extension PDFDocumentController {
    // MARK: Geometry

    var documentView: NSView? { scroller.clipView?.documentView }

    /// A page's rect in document view coordinates.
    func documentRect(of page: PDFPage) -> CGRect? {
        guard let documentView else { return nil }
        let inView = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        return documentView.convert(inView, from: pdfView)
    }

    func documentRect(ofPageAt index: Int) -> CGRect? {
        document?.page(at: index).flatMap(documentRect(of:))
    }

    /// The page under a document-view point (nearest page in gaps).
    func page(atDocumentPoint point: CGPoint) -> PDFPage? {
        guard let documentView else { return pdfView.currentPage }
        return pdfView.page(for: pdfView.convert(point, from: documentView), nearest: true)
    }

    /// The point used to decide which page the viewport "is on": just inside
    /// its top-left corner (the left page in two-up layouts).
    private func topProbe(for origin: CGPoint) -> CGPoint {
        CGPoint(x: max(origin.x, documentView?.bounds.minX ?? 0) + 1, y: origin.y + 1)
    }

    private func pageIndex(atOrigin origin: CGPoint) -> Int {
        guard let document, let page = page(atDocumentPoint: topProbe(for: origin)) else {
            return currentPageIndex
        }
        return document.index(for: page)
    }

    // MARK: Scrolling

    /// Vertical scroll position as 0–100, nil when the document fits.
    var scrollPercentage: Int? {
        guard let viewport = scroller.viewport, let bounds = documentView?.bounds else { return nil }
        let range = bounds.height - viewport.height
        guard range > 0.5 else { return nil }
        // The document view is flipped: minY is the top of the first page.
        let fraction = (viewport.minY - bounds.minY) / range
        return Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// Refresh the status (position %) whenever the clip view scrolls.
    func observeScrollPosition() {
        guard !isObservingScroll, let clipView = scroller.clipView else { return }
        isObservingScroll = true
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipViewDidScroll),
                                               name: NSView.boundsDidChangeNotification, object: clipView)
    }

    @objc private func clipViewDidScroll() { scheduleStatusUpdate() }

    /// Scrolls by view points (positive = down / right).
    func scroll(viewDX: Double, viewDY: Double) {
        guard scroller.viewport != nil else {
            // No scroll view found: degrade to page flips.
            if viewDY > 0 { pdfView.goToNextPage(nil) } else if viewDY < 0 { pdfView.goToPreviousPage(nil) }
            return
        }
        let s = scroller.scale
        let delta = CGVector(dx: viewDX / s, dy: viewDY / s)
        if !isContinuous, delta.dy != 0, flipPageAtEdge(forward: delta.dy > 0) { return }
        scroller.scroll(by: delta)
    }

    /// Scrolls by a fraction of the visible height.
    func scroll(screens: Double) {
        let height = scroller.clipView?.frame.height ?? pdfView.bounds.height
        scroll(viewDX: 0, viewDY: height * screens)
    }

    /// Single-page mode: scrolling past the bottom edge shows the next page's
    /// top (and past the top edge the previous page's bottom).
    private func flipPageAtEdge(forward: Bool) -> Bool {
        guard let destination = scroller.destination, let bounds = documentView?.bounds else { return false }
        let edge = scroller.clamp(CGPoint(x: destination.x, y: forward ? bounds.maxY : bounds.minY))
        guard abs(destination.y - edge.y) < 0.5 else { return false }
        if forward {
            guard pdfView.canGoToNextPage else { return false }
            pdfView.goToNextPage(nil)
        } else {
            guard pdfView.canGoToPreviousPage else { return false }
            pdfView.goToPreviousPage(nil)
        }
        pdfView.layoutDocumentView()
        let newBounds = documentView?.bounds ?? bounds
        scroller.set(CGPoint(x: destination.x, y: forward ? newBounds.minY : newBounds.maxY))
        return true
    }

    // MARK: Pages

    /// page-next / page-previous: aligns the top of the page `rows` rows away
    /// with the top of the viewport, keeping the horizontal offset.
    func goToAdjacentPage(by rows: Int) {
        guard let document, let destination = scroller.destination, isContinuous else {
            for _ in 0..<abs(rows) {
                if rows > 0 { pdfView.goToNextPage(nil) } else { pdfView.goToPreviousPage(nil) }
            }
            showTopOfCurrentPage()
            return
        }
        var index = pageIndex(atOrigin: destination)
        for _ in 0..<abs(rows) {
            guard let next = adjacentRow(from: index, forward: rows > 0, in: document) else { break }
            index = next
        }
        if let rect = documentRect(ofPageAt: index) {
            scroller.jump(to: CGPoint(x: destination.x, y: rect.minY))
        }
    }

    /// The first page of the next / previous row (rows matter in two-up).
    private func adjacentRow(from index: Int, forward: Bool, in document: PDFDocument) -> Int? {
        guard let top = documentRect(ofPageAt: index)?.minY else { return nil }
        let candidates = forward ? Array(index + 1..<document.pageCount) : Array((0..<index).reversed())
        guard let hit = candidates.first(where: { i in
            guard let y = documentRect(ofPageAt: i)?.minY else { return false }
            return forward ? y > top + 1 : y < top - 1
        }) else { return nil }
        // Walk back to the row's first page.
        guard !forward, let rowTop = documentRect(ofPageAt: hit)?.minY else { return hit }
        var first = hit
        while first > 0, let y = documentRect(ofPageAt: first - 1)?.minY, abs(y - rowTop) < 1 { first -= 1 }
        return first
    }

    /// goto-page / counted gg and G. `number` is 1-based and clamped.
    func goToPage(number: Int) {
        guard let document else { return }
        let index = min(max(number, 1), document.pageCount) - 1
        willJump()
        show(pageAt: index, animated: true)
    }

    /// Plain gg / G: the very top or bottom of the document.
    func goToDocumentEdge(end: Bool) {
        willJump()
        guard isContinuous, let destination = scroller.destination, let bounds = documentView?.bounds else {
            if end { pdfView.goToLastPage(nil) } else { pdfView.goToFirstPage(nil) }
            showTopOfCurrentPage()
            return
        }
        scroller.jump(to: CGPoint(x: destination.x, y: end ? bounds.maxY : bounds.minY))
    }

    /// Puts the top of a page at the top of the viewport, keeping x.
    func show(pageAt index: Int, animated: Bool) {
        guard let page = document?.page(at: index) else { return }
        guard isContinuous, scroller.viewport != nil else {
            pdfView.go(to: page)
            showTopOfCurrentPage()
            return
        }
        guard let rect = documentRect(of: page), let destination = scroller.destination else { return }
        let origin = CGPoint(x: destination.x, y: rect.minY)
        if animated { scroller.jump(to: origin) } else { scroller.set(origin) }
    }

    /// Non-continuous modes: after changing page, start at its top.
    private func showTopOfCurrentPage() {
        pdfView.layoutDocumentView()
        guard let x = scroller.destination?.x, let bounds = documentView?.bounds else { return }
        scroller.set(CGPoint(x: x, y: bounds.minY))
    }

    // MARK: Positions

    /// Where the viewport's top-left corner is (or is animating to). The
    /// fractions are in the page's unrotated space, relative to its
    /// `referenceBox` (the untrimmed box, so marks survive toggling trim),
    /// and may fall slightly outside 0...1 when the corner is in the gap
    /// around a page; that keeps round trips through `go(to:)` exact.
    var currentPosition: DocumentPosition {
        let zoom = pdfView.scaleFactor
        guard let document, let documentView, let origin = scroller.destination,
              let page = page(atDocumentPoint: topProbe(for: origin)) else {
            return DocumentPosition(page: currentPageIndex, zoom: zoom)
        }
        let point = pdfView.convert(pdfView.convert(origin, from: documentView), to: page)
        let box = referenceBox(of: page)
        return DocumentPosition(page: document.index(for: page),
                                x: (point.x - box.minX) / box.width,
                                y: (box.maxY - point.y) / box.height,
                                zoom: zoom)
    }

    /// Jumps to a mark / jump-list position. Restores its zoom if it has one.
    func go(to position: DocumentPosition, animated: Bool) {
        guard hasInitialLayout else {
            deferUntilLaidOut { [weak self] in self?.go(to: position, animated: animated) }
            return
        }
        if let zoom = position.zoom, abs(zoom - pdfView.scaleFactor) > 0.0005 {
            setScale(zoom)
        }
        restore(position, animated: animated)
    }

    /// Scrolls so the viewport's top-left corner is at `position`, without
    /// touching zoom or the jump list.
    func restore(_ position: DocumentPosition, animated: Bool) {
        guard let document, document.pageCount > 0 else { return }
        let page = document.page(at: min(max(position.page, 0), document.pageCount - 1))!
        if !isContinuous || scroller.viewport == nil {
            pdfView.go(to: page)
            pdfView.layoutDocumentView()
        }
        guard let documentView else { return }
        let box = referenceBox(of: page)
        var pagePoint = CGPoint(x: box.minX + position.x * box.width, y: box.maxY - position.y * box.height)
        if trimmer.isOn {
            // A spot in a trimmed-away margin: the nearest visible edge, so
            // the same page stays at the top of the viewport.
            let shown = page.bounds(for: pdfView.displayBox)
            let gap = pdfView.pageBreakMargins
            pagePoint.y = min(max(pagePoint.y, shown.minY - gap.bottom), shown.maxY + gap.top)
        }
        let origin = documentView.convert(pdfView.convert(pagePoint, from: page), from: pdfView)
        if animated { scroller.jump(to: origin) } else { scroller.set(origin) }
    }

    /// Called right before every non-incremental jump (gg, G, goto-page,
    /// search hits, go(to:)).
    func willJump() {
        host?.recordJump(from: currentPosition)
    }
}
