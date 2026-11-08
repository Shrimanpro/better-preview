import Foundation
import UniformTypeIdentifiers
import BPCore

struct PaletteItem {
    enum Kind: String { case recent, file, heading }
    let kind: Kind
    /// What the matcher sees: relative path for files, title for headings.
    let text: String
    /// Characters of `text` that form the directory part (including the slash).
    let dirLength: Int
    let url: URL?
    let entry: OutlineEntry?
    var indent: Int = 0

    var display: String { String(repeating: " ", count: indent) + text }
}

struct PaletteResult {
    let item: PaletteItem
    let positions: [Int]
}

/// Items from all sources and the ranking over them.
@MainActor
final class PaletteModel {
    private let root: String
    private let recents: [PaletteItem]
    private let headings: [PaletteItem]
    private var recentPaths: Set<String>
    private(set) var files: [PaletteItem] = []

    init(directory: URL, recentURLs: [URL], outline: [OutlineEntry]) {
        root = directory.standardizedFileURL.path + "/"
        var seen = Set<String>()
        var recents: [PaletteItem] = []
        for url in recentURLs where seen.insert(url.standardizedFileURL.path).inserted {
            recents.append(Self.fileItem(url, kind: .recent, root: root))
        }
        self.recents = recents
        recentPaths = seen
        headings = outline.map {
            PaletteItem(kind: .heading, text: $0.title, dirLength: 0, url: nil, entry: $0,
                        indent: $0.level * 2)
        }
    }

    func addFiles(_ urls: [URL]) {
        for url in urls where !recentPaths.contains(url.standardizedFileURL.path) {
            files.append(Self.fileItem(url, kind: .file, root: root))
        }
    }

    private static func fileItem(_ url: URL, kind: PaletteItem.Kind, root: String) -> PaletteItem {
        let path = url.standardizedFileURL.path
        let text = path.hasPrefix(root)
            ? String(path.dropFirst(root.count))
            : (path as NSString).abbreviatingWithTildeInPath
        let dirLength = text.lastIndex(of: "/").map { text.distance(from: text.startIndex, to: $0) + 1 } ?? 0
        return PaletteItem(kind: kind, text: text, dirLength: dirLength, url: url, entry: nil)
    }

    /// `@query` restricts to headings. Empty query: recents, headings, then files alphabetically.
    func results(for query: String, limit: Int = 200) -> [PaletteResult] {
        if query.hasPrefix("@") {
            return rank(String(query.dropFirst()), in: headings, limit: limit)
        }
        if query.isEmpty {
            let sorted = files.sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
            return (recents + headings + sorted).prefix(limit).map { PaletteResult(item: $0, positions: []) }
        }
        return rank(query, in: recents + files + headings, limit: limit)
    }

    private func rank(_ query: String, in items: [PaletteItem], limit: Int) -> [PaletteResult] {
        if query.isEmpty { return items.prefix(limit).map { PaletteResult(item: $0, positions: []) } }
        return FuzzyMatcher.rank(query, in: items, limit: limit) { $0.text }.map {
            PaletteResult(item: $0.item, positions: $0.match.positions)
        }
    }
}

/// Background enumeration of openable files below a directory.
final class PaletteScanner: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    private static let skipped: Set<String> = ["node_modules", ".git", "build", "DerivedData"]
    static let maxEntries = 5000
    static let maxDepth = 3

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func run(root: URL, batch: @escaping @Sendable ([URL]) -> Void,
             done: @escaping @Sendable (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return done(false) }
            var found = 0
            var pending: [URL] = []
            var openable: [String: Bool] = [:]
            while let url = walker.nextObject() as? URL, found < Self.maxEntries {
                if self.isCancelled { return done(false) }
                if (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true {
                    if Self.skipped.contains(url.lastPathComponent) || walker.level >= Self.maxDepth {
                        walker.skipDescendants()
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                let ok = openable[ext] ?? {
                    let type = UTType(filenameExtension: ext)
                    let value = type.map { $0.conforms(to: .pdf) || $0.conforms(to: .image) } ?? false
                    openable[ext] = value
                    return value
                }()
                guard ok else { continue }
                pending.append(url)
                found += 1
                if pending.count >= 250 { batch(pending); pending = [] }
            }
            if !pending.isEmpty { batch(pending) }
            done(!self.isCancelled)
        }
    }
}

/// Last enumeration, kept briefly so reopening is instant.
@MainActor
enum PaletteCache {
    private static var directory: URL?
    private static var urls: [URL] = []
    private static var stamp = Date.distantPast
    private static let lifetime: TimeInterval = 30

    static func files(for dir: URL) -> [URL]? {
        guard directory == dir, Date().timeIntervalSince(stamp) < lifetime else { return nil }
        return urls
    }

    static func store(_ files: [URL], for dir: URL) {
        directory = dir; urls = files; stamp = Date()
        let mine = stamp
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime + 1))
            if stamp == mine { directory = nil; urls = [] }
        }
    }
}
