import Foundation

public struct FuzzyMatch: Sendable {
    public let score: Int
    /// Character offsets in the candidate, ascending, one per query character.
    public let positions: [Int]
}

/// fzf-style subsequence matcher with an optimal alignment (dynamic programming).
public enum FuzzyMatcher {
    /// nil if `query` is not a subsequence of `candidate`. An empty query matches
    /// everything with score 0. Smart case: case-insensitive unless `query`
    /// contains an uppercase letter.
    public static func match(_ query: String, in candidate: String) -> FuzzyMatch? {
        var engine = FuzzyEngine(query: query)
        return engine.run(candidate, wantPositions: true)
    }

    /// Ranked best-first; equal scores keep their original order. At most
    /// `limit` results. Scores every item without allocating positions, then
    /// computes positions only for the survivors.
    public static func rank<T>(
        _ query: String, in items: [T], limit: Int = 50, key: (T) -> String
    ) -> [(item: T, match: FuzzyMatch)] {
        guard limit > 0 else { return [] }
        var engine = FuzzyEngine(query: query)
        var scored: [(index: Int, score: Int)] = []
        for (i, item) in items.enumerated() {
            if let m = engine.run(key(item), wantPositions: false) {
                scored.append((i, m.score))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return scored.prefix(limit).compactMap { entry in
            let item = items[entry.index]
            guard let m = engine.run(key(item), wantPositions: true) else { return nil }
            return (item, m)
        }
    }
}
