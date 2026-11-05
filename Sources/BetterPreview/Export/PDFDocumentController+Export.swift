import AppKit
import PDFKit

/// Saving.
extension PDFDocumentController {
    /// Writes the document in place (nil) or as a copy. Atomic; read-only
    /// files and missing folders are refused with a readable error.
    func savePDF(to url: URL?) throws {
        guard let document else { return }
        let destination = url ?? fileURL
        let inPlace = destination.standardizedFileURL == fileURL.standardizedFileURL
        // A file that went away is simply written again. PDFKit keeps the
        // encryption (passwords and permissions) of an unlocked document.
        try withPristinePages { try PDFExporter.writePDF(document, to: destination) }
        if inPlace { isDirty = false }
    }
}
