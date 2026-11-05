/// In-memory input bar history for one kind of input (`:` lines or search
/// queries): newest last, de-duplicated, capped. Browsing with `older` /
/// `newer` keeps the text that was being typed and returns it past the newest
/// entry.
struct CommandHistory {
    private var entries: [String] = []
    private let capacity = 100
    /// Index into `entries` while browsing; nil when editing fresh text.
    private var cursor: Int?
    private var draft = ""

    var last: String? { entries.last }

    mutating func add(_ entry: String) {
        cursor = nil
        guard !entry.isEmpty else { return }
        entries.removeAll { $0 == entry }
        entries.append(entry)
        if entries.count > capacity { entries.removeFirst(entries.count - capacity) }
    }

    /// Ends browsing; the next `older` starts from the newest entry.
    mutating func resetBrowsing() { cursor = nil }

    mutating func older(than text: String) -> String? {
        let index = (cursor ?? entries.count) - 1
        guard index >= 0 else { return nil }
        if cursor == nil { draft = text }
        cursor = index
        return entries[index]
    }

    mutating func newer() -> String? {
        guard let current = cursor else { return nil }
        if current + 1 < entries.count {
            cursor = current + 1
            return entries[current + 1]
        }
        cursor = nil
        return draft
    }
}
