import AppKit
import BPCore
import PDFKit

/// search-run / search-next / search-previous / search-clear.
extension PDFDocumentController {
    func runSearch(_ query: String) {
        guard !query.isEmpty, let document else {
            clearSearch()
            return
        }
        // Typing more of the query (incremental search): searching from the
        // previous hit is equivalent to searching from the original spot.
        let from: (page: Int, top: Double)
        if let hit = search.activeMatch, !search.query.isEmpty, query.hasPrefix(search.query) {
            from = (hit.page, hit.top)
        } else {
            let position = currentPosition
            from = (position.page, position.y)
        }
        search.start(query, in: document, smartCase: options.searchSmartCase)
        search.anchor = (from.page, from.top, searchDirectionBackward)
        refreshSearchHighlights(force: true)
        scheduleStatusUpdate()
    }

    /// Where a find may open a private copy of the document instead of
    /// searching the shown one (which would keep every page's text in
    /// memory): the file. Nil when modified. `PDFSearch` further checks
    /// that the file is unchanged and nothing was edited since it was loaded.
    var searchCopySource: URL? {
        isDirty ? nil : fileURL
    }

    /// After a reload: find the same text again without moving the view.
    func rerunSearchQuietly() {
        guard !search.query.isEmpty, let document else { return }
        let active = search.active
        search.start(search.query, in: document, smartCase: options.searchSmartCase)
        search.restoreActive = active
    }

    /// The search state an incremental `/` can overwrite and Esc must bring back.
    struct SearchMemento {
        var query: String
        var active: Int?
    }

    func searchMemento() -> SearchMemento {
        SearchMemento(query: search.query, active: search.active)
    }

    /// Brings back the results of an earlier search (quietly: no jump, no
    /// "pattern not found") or clears the search if there was none.
    func restoreSearch(_ memento: SearchMemento) {
        guard !memento.query.isEmpty, let document else { return clearSearch() }
        search.start(memento.query, in: document, smartCase: options.searchSmartCase)
        search.anchor = nil
        search.restoreActive = memento.active
        refreshSearchHighlights(force: true)
        scheduleStatusUpdate()
    }

    func clearSearch() {
        search.clear()
        refreshSearchHighlights(force: true)
        scheduleStatusUpdate()
    }

    /// n / N. `reverse` is N: opposite to the last search's direction.
    func stepSearch(by count: Int, reverse: Bool) {
        let total = search.matches.count
        guard total > 0 else {
            if !search.query.isEmpty, !search.isRunning {
                host?.showMessage("pattern not found: \(search.query)", isError: true)
            }
            return
        }
        let backward = searchDirectionBackward != reverse
        var index = search.active ?? (backward ? total : -1)
        for _ in 0..<count {
            var next = index + (backward ? -1 : 1)
            if next >= total || next < 0 {
                let edge = backward ? "TOP" : "BOTTOM"
                guard options.searchWrap else {
                    host?.showMessage("search hit \(edge) without match", isError: true)
                    break
                }
                next = backward ? total - 1 : 0
                host?.showMessage("search hit \(edge), continuing at \(backward ? "BOTTOM" : "TOP")", isError: false)
            }
            index = next
        }
        if index != search.active, (0..<total).contains(index) { activateMatch(index) }
    }

    // MARK: Results (called by PDFSearch)

    func searchDidFindMatch(at index: Int) {
        if let anchor = search.anchor {
            let matches = search.matches
            func beyond(_ i: Int) -> Bool { (matches[i].page, matches[i].top) > (anchor.page, anchor.top) }
            let atAnchor = (matches[index].page, matches[index].top) == (anchor.page, anchor.top)
            if !anchor.backward, beyond(index) || atAnchor {
                activateMatch(index)
            } else if anchor.backward, beyond(index), index > 0, !beyond(index - 1) {
                // The previous match is the last one at or before the anchor.
                activateMatch(index - 1)
            }
        }
        scheduleStatusUpdate()
    }

    func searchDidFinish() {
        let total = search.matches.count
        if let restore = search.restoreActive {
            search.active = restore < total ? restore : nil
        } else if let anchor = search.anchor {
            if total == 0 {
                host?.showMessage("pattern not found: \(search.query)", isError: true)
            } else if anchor.backward {
                // Every match is before the anchor, or none is (wrap).
                let first = search.matches[0]
                if (first.page, first.top) > (anchor.page, anchor.top) {
                    wrapToEdge(index: total - 1, message: "search hit TOP, continuing at BOTTOM")
                } else {
                    activateMatch(total - 1)
                }
            } else {
                wrapToEdge(index: 0, message: "search hit BOTTOM, continuing at TOP")
            }
        }
        search.anchor = nil
        search.restoreActive = nil
        refreshSearchHighlights(force: true)
        scheduleStatusUpdate()
    }

    private func wrapToEdge(index: Int, message: String) {
        guard options.searchWrap else {
            host?.showMessage("search hit \(index == 0 ? "BOTTOM" : "TOP") without match", isError: true)
            return
        }
        host?.showMessage(message, isError: false)
        activateMatch(index)
    }

    private func activateMatch(_ index: Int) {
        search.anchor = nil
        search.active = index
        willJump()
        if let selection = search.selection(at: index) { reveal(selection) }
        refreshSearchHighlights(force: true)
        scheduleStatusUpdate()
    }

    /// Scrolls a match into view unless it is already fully visible; it lands
    /// a third of the way down the viewport.
    private func reveal(_ selection: PDFSelection) {
        guard let page = selection.pages.first else { return }
        if !isContinuous, pdfView.currentPage != page {
            pdfView.go(to: page)
            pdfView.layoutDocumentView()
        }
        guard let documentView, let viewport = scroller.viewport, let origin = scroller.destination else {
            pdfView.go(to: selection)
            return
        }
        let rect = documentView.convert(pdfView.convert(selection.bounds(for: page), from: page), from: pdfView)
        let visible = CGRect(origin: origin, size: viewport.size)
        guard !visible.contains(rect) else { return }
        let x = rect.minX >= visible.minX && rect.maxX <= visible.maxX ? origin.x : rect.midX - visible.width / 2
        scroller.jump(to: CGPoint(x: x, y: rect.minY - visible.height / 3))
    }

    /// Highlights only the matches on pages near the viewport (plus the
    /// active one): `highlightedSelections` is scanned on every draw, and a
    /// common word can have 100k+ matches.
    func refreshSearchHighlights(force: Bool = false) {
        let matches = search.matches
        guard !matches.isEmpty, let theme else {
            if search.shownHighlights != nil || force, pdfView.highlightedSelections != nil {
                pdfView.highlightedSelections = nil
            }
            search.shownHighlights = nil
            return
        }
        let center = currentPageIndex
        let pages = max(0, center - 2)...(center + 3)
        let shown = (pages: pages, active: search.active, count: matches.count)
        if !force, let current = search.shownHighlights, current == shown { return }
        search.shownHighlights = shown

        // First match on or after the window's first page (matches are sorted).
        var low = 0, high = matches.count
        while low < high {
            let mid = (low + high) / 2
            if matches[mid].page < pages.lowerBound { low = mid + 1 } else { high = mid }
        }
        let color = theme.highlightColor.nsColor
        var selections: [PDFSelection] = []
        for index in low..<matches.count {
            guard matches[index].page <= pages.upperBound else { break }
            guard index != search.active, let selection = search.selection(at: index) else { continue }
            selection.color = color
            selections.append(selection)
        }
        if let active = search.active, let selection = search.selection(at: active) {
            selection.color = theme.highlightActiveColor.nsColor
            selections.append(selection)  // drawn last, on top
        }
        pdfView.highlightedSelections = selections
    }
}
