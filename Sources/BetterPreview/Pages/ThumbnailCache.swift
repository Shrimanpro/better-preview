import AppKit
import PDFKit

/// Lazily rendered page thumbnails with a bounded, least-recently-used cache.
///
/// Requests are queued on the main thread and rendered one at a time on a
/// background queue, newest request first; a request whose page is no
/// longer wanted (scrolled out of the sidebar) by the time its turn comes is
/// dropped. Entries are keyed by page object, so reordering pages keeps
/// them; an entry is stale when the page's rotation or the requested size
/// changed, or after `invalidateAll()` (recolor, trim, view rotation).
@MainActor
final class ThumbnailCache {
    /// Upper bound for cached bitmap memory.
    var byteLimit = 12 << 20
    /// Asked before rendering a queued page.
    var isWanted: (PDFPage) -> Bool = { _ in true }
    /// A thumbnail finished rendering.
    var didRender: (PDFPage, NSImage) -> Void = { _, _ in }

    private final class Entry {
        weak var page: PDFPage?
        let image: NSImage
        let rotation: Int
        let size: CGSize
        let generation: Int
        let cost: Int
        var lastUse: Int

        init(page: PDFPage, image: NSImage, size: CGSize, generation: Int, cost: Int, lastUse: Int) {
            self.page = page
            self.image = image
            rotation = page.rotation
            self.size = size
            self.generation = generation
            self.cost = cost
            self.lastUse = lastUse
        }
    }

    private struct Request {
        let page: PDFPage
        let size: CGSize
        let scale: CGFloat
        let box: PDFDisplayBox
    }

    /// Lets a page cross to the render queue (PDFKit renders pages off the
    /// main thread itself; `renderedThumbnail` is thread-safe).
    private struct Job: @unchecked Sendable {
        let page: PDFPage
        let size: CGSize
        let scale: CGFloat
        let box: PDFDisplayBox
    }

    private struct ImageBox: @unchecked Sendable { let image: NSImage }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var bytes = 0
    private var clock = 0
    private var generation = 0
    private var pending: [Request] = []
    private var inFlight = false
    private let queue = DispatchQueue(label: "better-preview.thumbnails", qos: .userInitiated)

    var cachedBytes: Int { bytes }
    var cachedCount: Int { entries.count }

    /// The cached thumbnail, possibly stale (a fine placeholder), and
    /// whether it is current. A missing or stale one is queued for rendering.
    func image(for page: PDFPage, size: CGSize, scale: CGFloat, box: PDFDisplayBox) -> (NSImage?, current: Bool) {
        let id = ObjectIdentifier(page)
        var cached: Entry?
        if let entry = entries[id] {
            if entry.page === page {
                cached = entry
            } else {
                remove(id)
            }
        }
        clock += 1
        cached?.lastUse = clock
        if let cached, cached.generation == generation, cached.rotation == page.rotation,
           abs(cached.size.width - size.width) < 1, abs(cached.size.height - size.height) < 1 {
            return (cached.image, true)
        }
        // Stale after recolor/trim changes: not a useful placeholder.
        let placeholder = cached?.generation == generation ? cached?.image : nil
        pending.removeAll { $0.page === page }
        pending.append(Request(page: page, size: size, scale: scale, box: box))
        pump()
        return (placeholder, false)
    }

    /// Everything must be re-rendered (recolor, trim or view rotation changed).
    func invalidateAll() {
        generation += 1
        pending.removeAll()
    }

    /// Drops all bitmaps (sidebar hidden).
    func purge() {
        entries.removeAll()
        bytes = 0
        pending.removeAll()
        generation += 1
    }

    private func pump() {
        guard !inFlight else { return }
        while let request = pending.popLast() {
            guard request.page.document != nil, isWanted(request.page) else { continue }
            inFlight = true
            let job = Job(page: request.page, size: request.size, scale: request.scale, box: request.box)
            let generation = generation
            queue.async { [weak self] in
                let image = ImageBox(image: job.page.renderedThumbnail(of: job.size, for: job.box, scale: job.scale))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.inFlight = false
                        if generation == self.generation {
                            self.store(image.image, for: job.page, size: job.size, scale: job.scale)
                            self.didRender(job.page, image.image)
                        }
                        self.pump()
                    }
                }
            }
            return
        }
    }

    private func store(_ image: NSImage, for page: PDFPage, size: CGSize, scale: CGFloat) {
        let id = ObjectIdentifier(page)
        remove(id)
        clock += 1
        let cost = Int(image.size.width * scale) * Int(image.size.height * scale) * 4
        entries[id] = Entry(page: page, image: image, size: size, generation: generation, cost: cost, lastUse: clock)
        bytes += cost
        evict()
    }

    private func remove(_ id: ObjectIdentifier) {
        if let old = entries.removeValue(forKey: id) { bytes -= old.cost }
    }

    /// Least recently used first; sorting only when over the limit keeps the
    /// common path O(1).
    private func evict() {
        guard bytes > byteLimit else { return }
        let target = byteLimit * 3 / 4
        for (id, _) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            guard bytes > target else { break }
            remove(id)
        }
    }
}
