import Foundation

/// Reusable scratch state for scoring many candidates against one query.
struct FuzzyEngine {
    private static let neg = Int.min / 4
    private static let base = 16
    private static let consecutive = 5
    private static let gapStart = 3
    private static let gapExtend = 1
    private static let leadPenalty = 1
    private static let leadCap = 8
    private static let filenameBonus = 4

    private let query: [UInt32]
    private let caseSensitive: Bool

    private var raw: [UInt32] = []
    private var cmp: [UInt32] = []
    private var bonus: [Int] = []
    private var prev: [Int] = []
    private var cur: [Int] = []
    private var pred: [Int32] = []

    init(query: String) {
        let scalars = query.unicodeScalars
        let sensitive = scalars.contains { Self.isUpper($0.value) }
        caseSensitive = sensitive
        self.query = scalars.map { sensitive ? $0.value : Self.fold($0.value) }
    }

    mutating func run(_ candidate: String, wantPositions: Bool) -> FuzzyMatch? {
        let n = query.count
        if n == 0 { return FuzzyMatch(score: 0, positions: []) }

        raw.removeAll(keepingCapacity: true)
        cmp.removeAll(keepingCapacity: true)
        var ascii = true
        for s in candidate.unicodeScalars {
            let v = s.value
            if v > 127 { ascii = false }
            raw.append(v)
            cmp.append(caseSensitive ? v : Self.fold(v))
        }
        let m = raw.count
        guard m >= n else { return nil }

        var qi = 0
        for c in cmp where qi < n && c == query[qi] { qi += 1 }
        guard qi == n else { return nil }

        computeBonuses()
        let neg = Self.neg
        prev = [Int](repeating: neg, count: m)
        cur = [Int](repeating: neg, count: m)
        if wantPositions { pred = [Int32](repeating: -1, count: n * m) }

        for i in 0..<n {
            var gap = neg
            var gapK = -1
            for j in 0..<m {
                cur[j] = neg
                if i > 0 {
                    gap -= Self.gapExtend
                    if j >= 2, prev[j - 2] > neg / 2, prev[j - 2] - Self.gapStart > gap {
                        gap = prev[j - 2] - Self.gapStart
                        gapK = j - 2
                    }
                }
                guard cmp[j] == query[i], j >= i, m - j >= n - i else { continue }
                if i == 0 {
                    cur[j] = Self.base + bonus[j] - min(j, Self.leadCap) * Self.leadPenalty
                    continue
                }
                var best = neg
                var from = -1
                if j >= 1, prev[j - 1] > neg / 2 {
                    best = prev[j - 1] + Self.consecutive
                    from = j - 1
                }
                if gap > neg / 2, gap > best {
                    best = gap
                    from = gapK
                }
                if best > neg / 2 {
                    cur[j] = best + Self.base + bonus[j]
                    if wantPositions { pred[i * m + j] = Int32(from) }
                }
            }
            swap(&prev, &cur)
        }

        var bestScore = neg
        var bestJ = -1
        for j in 0..<m where prev[j] > bestScore {
            bestScore = prev[j]
            bestJ = j
        }
        guard bestJ >= 0 else { return nil }
        guard wantPositions else { return FuzzyMatch(score: bestScore, positions: []) }

        var scalarPositions = [Int](repeating: 0, count: n)
        var j = bestJ
        for i in stride(from: n - 1, through: 0, by: -1) {
            scalarPositions[i] = j
            j = Int(pred[i * m + j])
        }
        return FuzzyMatch(
            score: bestScore,
            positions: ascii ? scalarPositions : Self.characterOffsets(scalarPositions, in: candidate))
    }

    /// Per-position bonus: start of string, word starts, camelCase humps, and
    /// anything inside the last path component.
    private mutating func computeBonuses() {
        let m = raw.count
        bonus.removeAll(keepingCapacity: true)
        let fileStart = (raw.lastIndex(of: 0x2F)).map { $0 + 1 } ?? 0
        for j in 0..<m {
            var b = 0
            if j == 0 {
                b = 8
            } else {
                let p = raw[j - 1], c = raw[j]
                if p == 0x2F { b = 8 }
                else if p == 0x5F || p == 0x2D || p == 0x2E || p == 0x20 { b = 7 }
                else if Self.isLower(p) && Self.isUpper(c) { b = 7 }
                else if !Self.isAlnum(p) && Self.isAlnum(c) { b = 6 }
            }
            if j >= fileStart { b += Self.filenameBonus }
            bonus.append(b)
        }
    }

    private static func characterOffsets(_ scalarPositions: [Int], in s: String) -> [Int] {
        var map: [Int] = []
        for (ci, ch) in s.enumerated() {
            for _ in ch.unicodeScalars { map.append(ci) }
        }
        return scalarPositions.map { map[$0] }
    }

    private static func isUpper(_ v: UInt32) -> Bool {
        if v < 128 { return v >= 0x41 && v <= 0x5A }
        return Unicode.Scalar(v)?.properties.isUppercase ?? false
    }

    private static func isLower(_ v: UInt32) -> Bool {
        if v < 128 { return v >= 0x61 && v <= 0x7A }
        return Unicode.Scalar(v)?.properties.isLowercase ?? false
    }

    private static func isAlnum(_ v: UInt32) -> Bool {
        if v < 128 { return (v >= 0x30 && v <= 0x39) || (v | 0x20 >= 0x61 && v | 0x20 <= 0x7A) }
        return Unicode.Scalar(v)?.properties.isAlphabetic ?? false
    }

    private static func fold(_ v: UInt32) -> UInt32 {
        if v < 128 { return (v >= 0x41 && v <= 0x5A) ? v + 32 : v }
        guard let s = Unicode.Scalar(v) else { return v }
        let l = s.properties.lowercaseMapping.unicodeScalars
        return l.count == 1 ? l.first!.value : v
    }
}
