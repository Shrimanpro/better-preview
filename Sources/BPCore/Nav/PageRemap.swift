import Foundation

/// How page indices moved in one structural edit (insert, delete, reorder),
/// so positions keyed by page index (marks, the jump list) can follow their
/// pages. Built from page identities before and after the edit.
public struct PageRemap: Equatable, Sendable {
    /// For each old page index, its new index, or nil if the page is gone.
    public let mapping: [Int?]
    public let newCount: Int

    public init(mapping: [Int?], newCount: Int) {
        self.mapping = mapping
        self.newCount = max(0, newCount)
    }

    /// Matches pages by identity: `old` and `new` list the page identities in
    /// document order before and after the edit.
    public init<ID: Hashable>(old: [ID], new: [ID]) {
        var index: [ID: Int] = [:]
        for (i, id) in new.enumerated() where index[id] == nil { index[id] = i }
        self.init(mapping: old.map { index[$0] }, newCount: new.count)
    }

    /// The document was replaced (reload): pages are matched by index.
    public static func byIndex(oldCount: Int, newCount: Int) -> PageRemap {
        PageRemap(mapping: (0..<max(0, oldCount)).map { $0 < newCount ? $0 : nil }, newCount: newCount)
    }

    public var isIdentity: Bool {
        mapping.count == newCount && mapping.enumerated().allSatisfy { $0.element == $0.offset }
    }

    /// `pos` on the same page after the edit. A position on a removed page
    /// moves to the top of the nearest following surviving page (else the
    /// nearest preceding one); its offset within the old page is dropped.
    /// Nil when no pages are left.
    public func map(_ pos: DocumentPosition) -> DocumentPosition? {
        guard newCount > 0 else { return nil }
        guard pos.page >= 0, pos.page < mapping.count else {
            // Not a page the edit knew about: keep it in range.
            var moved = pos
            moved.page = min(max(pos.page, 0), newCount - 1)
            return moved
        }
        if let page = mapping[pos.page] {
            var moved = pos
            moved.page = page
            return moved
        }
        let after = mapping[(pos.page + 1)...].lazy.compactMap { $0 }.first
        let before = mapping[..<pos.page].reversed().lazy.compactMap { $0 }.first
        let page = after ?? before ?? 0
        return DocumentPosition(page: min(page, newCount - 1), x: pos.x, y: 0, zoom: pos.zoom)
    }
}

extension Marks {
    /// Moves every mark with its page; see `PageRemap.map`.
    public mutating func remap(_ remap: PageRemap) {
        for (name, pos) in all {
            if let moved = remap.map(pos) { set(name, moved) } else { remove(name) }
        }
    }
}

extension JumpList {
    /// Moves every entry with its page; see `PageRemap.map`. Entries that end
    /// up next to one on the same page are merged (the older one is kept),
    /// and the cursor stays on the entry it was on (or the next surviving one).
    public mutating func remap(_ remap: PageRemap) {
        rebuild { remap.map($0) }
    }
}
