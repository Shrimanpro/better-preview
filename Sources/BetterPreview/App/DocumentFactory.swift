import AppKit
import UniformTypeIdentifiers

/// Picks the controller for a file.
@MainActor
enum DocumentFactory {
    static func make(for url: URL) -> DocumentController? {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .pdf) == true {
            return PDFDocumentController(url: url)
        }
        // Known image types and, for unknown extensions, whatever ImageIO sniffs.
        return ImageDocumentController(url: url)
    }
}
