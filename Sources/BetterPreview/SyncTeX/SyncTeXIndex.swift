import CSyncTeX
import Foundation

/// A place in a TeX source file. `column` is 0 when SyncTeX did not record one
/// (most engines don't).
struct SyncTeXSource: Equatable, Sendable {
    var path: String
    var line: Int
    var column: Int
}

/// A box on a PDF page in SyncTeX's "visible" coordinates: PostScript points
/// from the top-left corner of the page's media box, y pointing down.
struct SyncTeXBox: Equatable, Sendable {
    /// 0-based page index.
    var page: Int
    /// `minY` is the top of the box (baseline minus height); `height`
    /// includes the depth below the baseline.
    var rect: CGRect
}

/// One parsed `.synctex(.gz)` file, wrapping the vendored C scanner.
///
/// The scanner is not thread-safe: create and query an index on one serial
/// queue (`SyncTeXFeature.queue`). Parsing reads the whole file, so never do
/// it on the main thread.
final class SyncTeXIndex: @unchecked Sendable {
    let pdfURL: URL
    let synctexURL: URL
    /// Modification date of `synctexURL` when it was parsed; the feature
    /// re-parses when it changes.
    let modificationDate: Date?
    private let scanner: OpaquePointer
    /// Input files as recorded by TeX, with their canonical paths.
    private lazy var inputs: [(name: String, canonical: String)] = loadInputs()

    /// The `.synctex.gz` (or plain `.synctex`) written next to a PDF.
    static func synctexFile(forPDF url: URL) -> URL? {
        let base = url.deletingPathExtension()
        for ext in ["synctex.gz", "synctex"] {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Parses the SyncTeX file for `pdfURL`. Nil when there is none or it
    /// cannot be read.
    init?(pdfURL: URL) {
        guard let file = Self.synctexFile(forPDF: pdfURL) else { return nil }
        let date = Self.modificationDate(of: file)
        guard let scanner = synctex_scanner_new_with_output_file(pdfURL.path, nil, 1) else { return nil }
        guard synctex_scanner_get_synctex(scanner) != nil else {
            synctex_scanner_free(scanner)
            return nil
        }
        self.pdfURL = pdfURL
        self.synctexURL = file
        self.modificationDate = date
        self.scanner = scanner
    }

    deinit {
        synctex_scanner_free(scanner)
    }

    // MARK: Inverse search (PDF -> source)

    /// The source line that produced the content at (`h`, `v`) on `page`
    /// (0-based), in visible coordinates.
    func source(page: Int, h: Double, v: Double) -> SyncTeXSource? {
        guard synctex_edit_query(scanner, Int32(page + 1), Float(h), Float(v)) > 0,
              let node = synctex_scanner_next_result(scanner) else { return nil }
        let tag = synctex_node_tag(node)
        guard let cName = synctex_scanner_get_name(scanner, tag) else { return nil }
        let line = Int(synctex_node_line(node))
        guard line > 0 else { return nil }
        return SyncTeXSource(path: canonicalPath(String(cString: cName)), line: line,
                             column: max(0, Int(synctex_node_column(node))))
    }

    // MARK: Forward search (source -> PDF)

    /// Boxes produced by `line` of `sourcePath`, best match first. All boxes
    /// returned are on the page of the best match.
    func boxes(sourcePath: String, line: Int, column: Int, pageHint: Int) -> [SyncTeXBox] {
        guard let name = recordedName(matching: sourcePath) else { return [] }
        let count = synctex_display_query(scanner, name, Int32(clamping: line), Int32(clamping: max(column, 0)),
                                          Int32(clamping: pageHint + 1))
        guard count > 0 else { return [] }
        var result: [SyncTeXBox] = []
        while let node = synctex_scanner_next_result(scanner) {
            let page = Int(synctex_node_page(node)) - 1
            guard page >= 0 else { continue }
            if let first = result.first, first.page != page { continue }
            let h = Double(synctex_node_box_visible_h(node))
            let v = Double(synctex_node_box_visible_v(node))
            let width = Double(synctex_node_box_visible_width(node))
            let height = Double(synctex_node_box_visible_height(node))
            let depth = Double(synctex_node_box_visible_depth(node))
            // Width can be negative for right-to-left material.
            let rect = CGRect(x: h, y: v - height, width: width, height: height + depth).standardized
            result.append(SyncTeXBox(page: page, rect: rect))
        }
        return result
    }

    /// The input name exactly as TeX recorded it, for a path given by an
    /// editor (which may be relative, symlinked, or differ in `./`).
    func recordedName(matching path: String) -> String? {
        let target = canonicalPath(path)
        if let hit = inputs.first(where: { $0.canonical == target }) { return hit.name }
        // Same file name in exactly one place: good enough (moved build dirs).
        let base = (target as NSString).lastPathComponent
        let sameName = inputs.filter { ($0.canonical as NSString).lastPathComponent == base }
        if sameName.count == 1 { return sameName[0].name }
        // Let the C library try its own fuzzy matching.
        return synctex_scanner_get_tag(scanner, path) != 0 ? path : nil
    }

    /// Absolute, standardized, symlink-resolved; relative names are taken
    /// relative to the PDF's directory (where TeX ran, in the usual setup).
    func canonicalPath(_ name: String) -> String {
        let expanded = (name as NSString).expandingTildeInPath
        let base = pdfURL.deletingLastPathComponent()
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
                                          : URL(fileURLWithPath: expanded, relativeTo: base)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func loadInputs() -> [(name: String, canonical: String)] {
        var list: [(String, String)] = []
        var node = synctex_scanner_input(scanner)
        while let current = node {
            if let cName = synctex_scanner_get_name(scanner, synctex_node_tag(current)) {
                let name = String(cString: cName)
                if !name.isEmpty { list.append((name, canonicalPath(name))) }
            }
            node = synctex_node_sibling(current)
        }
        return list
    }
}
