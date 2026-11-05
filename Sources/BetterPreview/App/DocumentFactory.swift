import AppKit
import UniformTypeIdentifiers

/// Picks the controller for a file.
@MainActor
enum DocumentFactory {
    static func make(for url: URL) -> DocumentController? {
        let type = UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .pdf) == true else { return nil }
        return PDFDocumentController(url: url)
    }
}
