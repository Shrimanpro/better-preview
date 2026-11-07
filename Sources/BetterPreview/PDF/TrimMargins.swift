import os
import PDFKit

/// Finds the content of a page: renders it small in grayscale and scans for
/// pixels that differ from the background (the median of the edge pixels).
/// Thread-safe; works on the CGPDFPage, so annotations and recolor are not
/// involved and a crop already applied to the page does not clip it.
enum ContentDetector {
    /// Longest side of the analysis bitmap, in pixels.
    static let resolution: CGFloat = 256
    /// Gray-level difference from the background that counts as content;
    /// high enough to ignore JPEG noise in scans.
    static let tolerance = 32

    /// The content's bounding box in page space, rounded outward to whole
    /// analysis pixels, or nil for an empty page.
    static func contentBox(of page: CGPDFPage, in box: CGRect) -> CGRect? {
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = resolution / max(box.width, box.height)
        let width = Int((box.width * scale).rounded(.up)), height = Int((box.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.clip(to: box)
        context.drawPDFPage(page)

        let stride = context.bytesPerRow
        func pixel(_ x: Int, _ y: Int) -> Int { Int(data[y * stride + x]) }
        var edge: [Int] = []
        for x in 0..<width { edge += [pixel(x, 0), pixel(x, height - 1)] }
        for y in 0..<height { edge += [pixel(0, y), pixel(width - 1, y)] }
        edge.sort()
        let background = edge[edge.count / 2]

        // Rows are top-down in memory.
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = data + y * stride
            for x in 0..<width where abs(Int(row[x]) - background) > tolerance {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: box.minX + CGFloat(minX) / scale, y: box.maxY - CGFloat(maxY + 1) / scale,
                      width: CGFloat(maxX + 1 - minX) / scale, height: CGFloat(maxY + 1 - minY) / scale)
            .intersection(box)
    }
}

/// Display-only margin trimming (zathura-style "fit to content").
///
/// Content boxes are detected per page on background queues and cached for
/// the document's life. Pages are cropped (their `.cropBox`, which PDFView
/// displays) to one consistent box per group of same-size pages of the same
/// parity: the union of the group's content, plus padding. Book margins
/// alternate, hence the parity split; odd and even crops of a page size get
/// the same width and height so pages do not change size while scrolling.
///
/// Order of work: the visible pages and the first 20 are analysed first and
/// the crop applied; the rest follows at utility QoS, and the crop is
/// re-applied once at the end only if a box moved by more than 2 points.
@MainActor
final class MarginTrimmer {
    /// Wraps every change of crop boxes: the controller notes the reading
    /// position, runs the change, then relayouts and restores the position.
    /// While the change runs `originalBox(of:)` still describes the old state.
    var performCropChange: (_ change: () -> Void) -> Void = { $0() }
    var padding: CGFloat = 6 {
        didSet { if isOn, padding != oldValue { applyCrops() } }
    }
    private(set) var isOn = false

    private weak var document: PDFDocument?
    /// Per page, keyed weakly by the page object itself (pointer identity):
    /// a freed page's entry can never match a new page at the same address.
    private var entries = NSMapTable<PDFPage, PageEntry>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                         valueOptions: .strongMemory)

    private final class PageEntry {
        /// Crop box before trimming.
        var original: CGRect?
        /// Detected content (nil = empty page). Absent = not analysed yet.
        var content: CGRect??
    }

    private func entry(_ page: PDFPage) -> PageEntry {
        if let existing = entries.object(forKey: page) { return existing }
        let created = PageEntry()
        entries.setObject(created, forKey: page)
        return created
    }
    /// What `applyCrops` set, per group.
    private var appliedCrops: [GroupKey: CGRect] = [:]
    private var job: Job?

    private struct GroupKey: Hashable {
        var odd: Bool
        var width: Int
        var height: Int
    }

    /// Cancellation flag shared with the background passes.
    private final class Job: @unchecked Sendable {
        private let cancelled = OSAllocatedUnfairLock(initialState: false)
        var isCancelled: Bool { cancelled.withLock { $0 } }
        func cancel() { cancelled.withLock { $0 = true } }
    }

    private struct Work: @unchecked Sendable {
        /// Only touched on the main thread.
        weak var owner: PDFPage?
        let page: CGPDFPage
        let box: CGRect
    }

    /// The page's untrimmed crop box while trimming, else nil.
    func originalBox(of page: PDFPage) -> CGRect? {
        isOn ? entries.object(forKey: page)?.original : nil
    }

    /// Turns trimming on. `priority` are page indices to analyse first.
    func start(document: PDFDocument, priority: [Int]) {
        if document !== self.document { reset(); self.document = document }
        guard !isOn else { return }
        isOn = true
        let sample = Set(priority + Array(0..<min(20, document.pageCount)))
        var first: [Work] = [], rest: [Work] = []
        var seen = Set<Int>()
        for index in priority + Array(0..<document.pageCount) {
            guard seen.insert(index).inserted, let page = document.page(at: index) else { continue }
            let info = entry(page)
            let box = info.original ?? page.bounds(for: .cropBox)
            info.original = box
            guard info.content == nil, let ref = page.pageRef else { continue }
            if sample.contains(index) {
                first.append(Work(owner: page, page: ref, box: box))
            } else {
                rest.append(Work(owner: page, page: ref, box: box))
            }
        }
        guard !first.isEmpty || !rest.isEmpty else {
            applyCrops()
            return
        }
        let job = Job()
        self.job = job
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.analyse(first, job)
            DispatchQueue.main.async { [weak self] in
                guard let self, !job.isCancelled else { return }
                store(found)
                applyCrops()
                analyseRest(rest, job)
            }
        }
    }

    /// Low-priority pass over the remaining pages, in chunks so results are
    /// cached even if trimming is turned off midway.
    private func analyseRest(_ tasks: [Work], _ job: Job) {
        guard !tasks.isEmpty else { return }
        let chunk = Array(tasks.prefix(64)), remaining = Array(tasks.dropFirst(64))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = Self.analyse(chunk, job)
            DispatchQueue.main.async { [weak self] in
                guard let self, !job.isCancelled else { return }
                store(found)
                if remaining.isEmpty {
                    finalise()
                } else {
                    analyseRest(remaining, job)
                }
            }
        }
    }

    private nonisolated static func analyse(_ tasks: [Work], _ job: Job) -> [(Work, CGRect?)] {
        var found: [(Work, CGRect?)] = []
        for task in tasks {
            guard !job.isCancelled else { break }
            found.append((task, ContentDetector.contentBox(of: task.page, in: task.box)))
        }
        return found
    }

    private func store(_ found: [(Work, CGRect?)]) {
        // A page freed meanwhile has no owner any more: drop its result.
        for (work, box) in found {
            if let page = work.owner { entry(page).content = .some(box) }
        }
    }

    /// End of the full pass: re-apply only if some crop moved noticeably.
    private func finalise() {
        let crops = computeCrops()
        let changed = crops.count != appliedCrops.count || crops.contains { key, rect in
            guard let old = appliedCrops[key] else { return true }
            return abs(old.minX - rect.minX) > 2 || abs(old.minY - rect.minY) > 2
                || abs(old.maxX - rect.maxX) > 2 || abs(old.maxY - rect.maxY) > 2
        }
        if changed { applyCrops() }
    }

    /// Restores every page's crop box and stops background work. The
    /// detected content stays cached.
    func stop() {
        guard isOn else { return }
        job?.cancel()
        job = nil
        performCropChange {
            isOn = false
            restoreOriginals()
            appliedCrops = [:]
        }
    }

    /// Forgets everything (new document after a reload).
    func reset() {
        job?.cancel()
        job = nil
        isOn = false
        entries.removeAllObjects()
        appliedCrops = [:]
        document = nil
    }

    /// Runs `body` with the untrimmed crop boxes in place (save, print).
    func withOriginalBoxes<T>(_ body: () throws -> T) rethrows -> T {
        guard isOn else { return try body() }
        restoreOriginals()
        defer { setCrops(appliedCrops) }
        return try body()
    }

    // MARK: Crops

    private func applyCrops() {
        performCropChange {
            appliedCrops = computeCrops()
            setCrops(appliedCrops)
        }
    }

    private func restoreOriginals() {
        forEachPage { page, info in
            if let original = info?.original, page.bounds(for: .cropBox) != original {
                page.setBounds(original, for: .cropBox)
            }
        }
    }

    private func setCrops(_ crops: [GroupKey: CGRect]) {
        forEachPage { page, info in
            guard let original = info?.original else { return }
            let crop = crops[groupKey(index: document?.index(for: page) ?? 0, box: original)]
                .map { $0.offsetBy(dx: original.minX, dy: original.minY).intersection(original) } ?? original
            if page.bounds(for: .cropBox) != crop { page.setBounds(crop, for: .cropBox) }
        }
    }

    private func forEachPage(_ body: (PDFPage, PageEntry?) -> Void) {
        guard let document else { return }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index) { body(page, entries.object(forKey: page)) }
        }
    }

    private func groupKey(index: Int, box: CGRect) -> GroupKey {
        GroupKey(odd: index % 2 == 1, width: Int(box.width.rounded()), height: Int(box.height.rounded()))
    }

    /// Crop per group, relative to the page box origin.
    private func computeCrops() -> [GroupKey: CGRect] {
        guard let document else { return [:] }
        var unions: [GroupKey: CGRect] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let info = entries.object(forKey: page)
            guard let original = info?.original, let content = info?.content ?? nil else { continue }
            let key = groupKey(index: index, box: original)
            let local = content.offsetBy(dx: -original.minX, dy: -original.minY)
            unions[key] = unions[key].map { $0.union(local) } ?? local
        }
        return Self.crops(unions: unions, padding: padding)
    }

    /// Pads each group's union and gives odd and even groups of a page size
    /// the same size (the larger), each centred on its own content.
    private static func crops(unions: [GroupKey: CGRect], padding: CGFloat) -> [GroupKey: CGRect] {
        var crops: [GroupKey: CGRect] = [:]
        for (key, union) in unions {
            var partner = key
            partner.odd.toggle()
            let other = unions[partner] ?? union
            let size = CGSize(width: max(union.width, other.width) + 2 * padding,
                              height: max(union.height, other.height) + 2 * padding)
            let page = CGRect(x: 0, y: 0, width: key.width, height: key.height)
            var crop = CGRect(x: union.midX - size.width / 2, y: union.midY - size.height / 2,
                              width: size.width, height: size.height)
            // Slide back inside the page, then clip if it is still too big.
            crop.origin.x = min(max(crop.minX, page.minX), max(page.maxX - crop.width, page.minX))
            crop.origin.y = min(max(crop.minY, page.minY), max(page.maxY - crop.height, page.minY))
            crops[key] = crop.intersection(page).integral
        }
        return crops
    }
}
