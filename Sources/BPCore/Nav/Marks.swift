import Foundation

/// Named positions, vim-style. Valid names are `a-z`, `A-Z` and `0-9`.
public struct Marks: Sendable {
    private var storage: [Character: DocumentPosition] = [:]

    public init() {}

    public static func isValidName(_ name: Character) -> Bool {
        guard name.isASCII else { return false }
        return name.isLetter || name.isNumber
    }

    /// Stores `pos` under `name`, replacing any previous mark. Invalid names
    /// are ignored; returns whether the mark was stored.
    @discardableResult
    public mutating func set(_ name: Character, _ pos: DocumentPosition) -> Bool {
        guard Self.isValidName(name) else { return false }
        storage[name] = pos
        return true
    }

    public func get(_ name: Character) -> DocumentPosition? { storage[name] }

    /// All marks sorted by name (digits, then uppercase, then lowercase).
    public var all: [(Character, DocumentPosition)] {
        storage.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    public mutating func removeAll() { storage.removeAll() }

    public mutating func remove(_ name: Character) { storage[name] = nil }

    /// Call after pages were removed. Marks on pages `>= pageCount` move to the
    /// last page, top-left (their offsets no longer mean anything). With no
    /// pages left every mark is dropped.
    public mutating func clamp(pageCount: Int) {
        guard pageCount > 0 else { return removeAll() }
        for (name, pos) in storage where pos.page >= pageCount {
            storage[name] = DocumentPosition(page: pageCount - 1, zoom: pos.zoom)
        }
    }
}
