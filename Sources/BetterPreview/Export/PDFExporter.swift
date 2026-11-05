import AppKit
import PDFKit

struct ExportFailure: LocalizedError {
    var errorDescription: String?
}

/// Atomic file replacement shared by save and export: the data is produced in
/// a temporary file next to the destination and swapped in only on success,
/// so a failure never damages the destination or the open file.
enum AtomicWrite {
    /// Throws a readable error for read-only files and unwritable folders
    /// before any work is done.
    static func preflight(_ url: URL) throws {
        let fm = FileManager.default
        let directory = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ExportFailure(errorDescription: "The folder “\(url.deletingLastPathComponent().lastPathComponent)” does not exist")
        }
        if fm.fileExists(atPath: url.path) {
            guard fm.isWritableFile(atPath: url.path) else {
                throw ExportFailure(errorDescription: "“\(url.lastPathComponent)” is read-only")
            }
        }
        guard fm.isWritableFile(atPath: directory) else {
            throw ExportFailure(errorDescription: "The folder “\(url.deletingLastPathComponent().lastPathComponent)” is not writable")
        }
    }

    static func write(to url: URL, _ produce: (URL) throws -> Void) throws {
        try preflight(url)
        let fm = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".bp-\(UUID().uuidString).tmp")
        do {
            try produce(temp)
            guard fm.fileExists(atPath: temp.path) else {
                throw ExportFailure(errorDescription: "Writing “\(url.lastPathComponent)” failed")
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: url)
            }
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }
}

/// Writes PDFs. Callers run it inside `withPristinePages`.
enum PDFExporter {
    /// Writes `document` as a PDF.
    static func writePDF(_ document: PDFDocument, to url: URL) throws {
        try AtomicWrite.write(to: url) { temp in
            guard document.write(to: temp) else { throw ExportFailure(errorDescription: "Could not write \(url.lastPathComponent)") }
        }
    }

    /// Some permission is withheld (printing, copying, editing, …).
    static func hasRestrictions(_ document: PDFDocument) -> Bool {
        !(document.allowsPrinting && document.allowsCopying && document.allowsDocumentChanges
          && document.allowsDocumentAssembly && document.allowsCommenting && document.allowsFormFieldEntry
          && document.allowsContentAccessibility)
    }

    /// Encrypted with owner restrictions and unlocked without owner rights:
    /// removing or replacing the encryption would drop the restrictions.
    static func needsOwnerPassword(_ document: PDFDocument) -> Bool {
        document.isEncrypted && document.permissionsStatus != .owner && hasRestrictions(document)
    }
}
