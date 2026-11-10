import AppKit

/// Signatures saved on disk as transparent PNGs in
/// `~/Library/Application Support/Better Preview/Signatures/`.
/// Directory mode 0700, files 0600. The file name (without extension) is the
/// signature's name. `BP_SIGNATURE_DIR` overrides the location (self-test).
@MainActor
final class SignatureStore {
    static var shared = SignatureStore()

    struct Entry {
        var name: String
        var url: URL
    }

    let directory: URL
    private var imageCache: [URL: CGImage] = [:]

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let override = ProcessInfo.processInfo.environment["BP_SIGNATURE_DIR"] {
            self.directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            self.directory = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Better Preview/Signatures", isDirectory: true)
        }
    }

    /// Saved signatures, oldest first.
    func list() -> [Entry] {
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        let dated = urls.filter { $0.pathExtension.lowercased() == "png" }.map { url in
            (url, (try? url.resourceValues(forKeys: Set(keys)).creationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 < $1.1 || ($0.1 == $1.1 && $0.0.lastPathComponent < $1.0.lastPathComponent) }
            .map { Entry(name: $0.0.deletingPathExtension().lastPathComponent, url: $0.0) }
    }

    func entry(named query: String) -> Entry? {
        let all = list()
        if let index = Int(query), all.indices.contains(index - 1) { return all[index - 1] }
        return all.first { $0.name.caseInsensitiveCompare(query) == .orderedSame }
            ?? all.first { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func image(for entry: Entry) -> CGImage? {
        if let cached = imageCache[entry.url] { return cached }
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        imageCache[entry.url] = image
        return image
    }

    /// Writes `image` as a new signature and returns its entry.
    @discardableResult
    func add(_ image: CGImage, name: String? = nil) throws -> Entry {
        try ensureDirectory()
        let base = Self.sanitized(name) ?? nextDefaultName()
        var url = directory.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).png")
            n += 1
        }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Create with the final mode so the signature is never world-readable.
        guard FileManager.default.createFile(atPath: url.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        imageCache[url] = image
        return Entry(name: url.deletingPathExtension().lastPathComponent, url: url)
    }

    func delete(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        imageCache[entry.url] = nil
    }

    func rename(_ entry: Entry, to newName: String) -> Bool {
        guard let name = Self.sanitized(newName) else { return false }
        let target = directory.appendingPathComponent(name + ".png")
        guard !FileManager.default.fileExists(atPath: target.path),
              (try? FileManager.default.moveItem(at: entry.url, to: target)) != nil else { return false }
        imageCache[target] = imageCache[entry.url]
        imageCache[entry.url] = nil
        return true
    }

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        // Tighten parents we created and the directory itself if it pre-existed.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func nextDefaultName() -> String {
        let existing = Set(list().map(\.name))
        var n = existing.count + 1
        while existing.contains("Signature \(n)") { n += 1 }
        return "Signature \(n)"
    }

    private static func sanitized(_ name: String?) -> String? {
        guard let name else { return nil }
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\\0")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? nil : cleaned
    }
}
