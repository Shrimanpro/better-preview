import Foundation

/// Vim-style jump list (Ctrl-o / Ctrl-i) over document positions.
///
/// Semantics:
/// - `record` stores the position being *left* right before a jump. If the
///   cursor is in the past (after `back`), the newer entries are discarded
///   first. A position on the same page as the newest entry replaces it
///   instead of adding a duplicate. The cursor ends at the tip.
/// - `back(from:)` at the tip saves `current` (replacing the newest entry if it
///   is on the same page) so `forward` can return to it, then steps to the
///   previous entry. Returns nil, changing nothing, if there is none.
/// - `forward` steps to the next entry, nil when already at the newest.
/// - The oldest entries are dropped beyond `capacity`.
public struct JumpList: Sendable {
    private var entries: [DocumentPosition] = []
    /// Index of the entry the view corresponds to; `entries.count` = at the tip.
    private var cursor = 0
    private let capacity: Int

    /// The stored positions, oldest first (excluding the cursor).
    public var positions: [DocumentPosition] { entries }

    public init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    public mutating func record(_ pos: DocumentPosition) {
        if cursor < entries.count { entries.removeSubrange((cursor + 1)...) }
        append(pos)
        cursor = entries.count
    }

    public mutating func back(from current: DocumentPosition) -> DocumentPosition? {
        if cursor >= entries.count {
            guard !entries.isEmpty else { return nil }
            let grows = entries[entries.count - 1].page != current.page
            guard min(capacity, entries.count + (grows ? 1 : 0)) >= 2 else { return nil }
            append(current)
            cursor = entries.count - 2
            return entries[cursor]
        }
        guard cursor > 0 else { return nil }
        cursor -= 1
        return entries[cursor]
    }

    public mutating func forward() -> DocumentPosition? {
        guard cursor + 1 < entries.count else { return nil }
        cursor += 1
        return entries[cursor]
    }

    public mutating func removeAll() {
        entries.removeAll()
        cursor = 0
    }

    /// Replaces every entry with `transform(entry)`, dropping nils and
    /// merging neighbours that land on the same page (the older one is kept).
    /// The cursor follows its entry, else the next surviving one, else the tip.
    mutating func rebuild(_ transform: (DocumentPosition) -> DocumentPosition?) {
        var result: [DocumentPosition] = []
        var newIndex: [Int?] = []
        for entry in entries {
            guard let moved = transform(entry) else {
                newIndex.append(nil)
                continue
            }
            if let last = result.last, last.page == moved.page {
                newIndex.append(result.count - 1)
            } else {
                result.append(moved)
                newIndex.append(result.count - 1)
            }
        }
        let atTip = cursor >= entries.count
        entries = result
        cursor = atTip ? entries.count : (newIndex[cursor...].lazy.compactMap { $0 }.first ?? entries.count)
    }

    private mutating func append(_ pos: DocumentPosition) {
        if let last = entries.last, last.page == pos.page {
            entries[entries.count - 1] = pos
        } else {
            entries.append(pos)
        }
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }
}
