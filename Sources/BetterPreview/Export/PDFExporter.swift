import AppKit
import PDFKit

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

/// Writes PDFs (optionally smaller or encrypted) and page images. Callers run
/// it inside `withPristinePages`.
enum PDFExporter {
    /// PDFKit write options for `options`; nil when plain.
    static func writeOptions(for options: PDFExportOptions) -> [PDFDocumentWriteOption: Any]? {
        var result: [PDFDocumentWriteOption: Any] = [:]
        if options.reduceSize {
            result[.optimizeImagesForScreenOption] = true
            result[.saveImagesAsJPEGOption] = true
        }
        if options.wantsEncryption {
            let open = options.openPassword ?? ""
            let owner = (options.ownerPassword ?? "").isEmpty ? open : options.ownerPassword!
            if !open.isEmpty { result[.userPasswordOption] = open }
            result[.ownerPasswordOption] = owner
            result[.accessPermissionsOption] = NSNumber(value: options.permissions)
        }
        return result.isEmpty ? nil : result
    }

    /// Writes `document` as a PDF.
    static func writePDF(_ document: PDFDocument, to url: URL, options: PDFExportOptions) throws {
        let write = writeOptions(for: options)
        try AtomicWrite.write(to: url) { temp in
            let ok = write.map { document.write(to: temp, withOptions: $0) } ?? document.write(to: temp)
            guard ok else { throw ExportFailure(errorDescription: "Could not write \(url.lastPathComponent)") }
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

    /// The options remove or replace the document's encryption.
    static func changesEncryption(_ options: PDFExportOptions) -> Bool {
        options.format == .pdf && (options.stripEncryption || options.wantsEncryption)
    }

    /// The files an export writes: `url`, or `name-01.ext`… for one image per page.
    static func targets(for document: PDFDocument, currentPage: Int, url: URL,
                        options: PDFExportOptions) -> [URL] {
        guard options.format.isImage, !options.currentPageOnly, document.pageCount > 1 else { return [url] }
        let digits = String(document.pageCount).count
        let stem = url.deletingPathExtension()
        return (0..<document.pageCount).map { index in
            let number = String(format: "%0\(digits)d", index + 1)
            return URL(fileURLWithPath: stem.path + "-\(number)").appendingPathExtension(url.pathExtension)
        }
    }

    /// Exports to `url` in the options' format; returns the files written.
    @discardableResult
    static func export(_ document: PDFDocument, currentPage: Int, to url: URL,
                       options: PDFExportOptions) throws -> [URL] {
        try options.validate()
        guard document.pageCount > 0 else { throw ExportFailure(errorDescription: "The document has no pages") }
        if changesEncryption(options), needsOwnerPassword(document) {
            throw ExportFailure(errorDescription:
                "The document's owner restricts it; removing or changing its encryption needs the owner password")
        }
        if options.format == .pdf {
            let source = options.stripEncryption && !options.wantsEncryption && document.isEncrypted
                ? decryptedCopy(of: document) : document
            try writePDF(source, to: url, options: options)
            return [url]
        }
        let indices = options.currentPageOnly ? [min(max(currentPage, 0), document.pageCount - 1)]
            : Array(0..<document.pageCount)
        let targets = targets(for: document, currentPage: currentPage, url: url, options: options)
        // Check every destination first: a failure then leaves nothing half written.
        for target in targets { try AtomicWrite.preflight(target) }
        for (index, target) in zip(indices, targets) {
            guard let page = document.page(at: index), let image = render(page, dpi: options.dpi) else {
                throw ExportFailure(errorDescription: "Could not render page \(index + 1)")
            }
            let size = CGSize(width: options.dpi, height: options.dpi)
            try ImageEncoder.write(image, to: target, type: options.format.type, quality: options.quality, dpi: size)
        }
        return targets
    }

    /// A copy without encryption. PDFKit keeps the encryption when it writes
    /// an unlocked document, so the pages (and outline) go into a new one.
    static func decryptedCopy(of document: PDFDocument) -> PDFDocument {
        let copy = PDFDocument()
        var pages: [PDFPage: PDFPage] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let new = page.copy() as? PDFPage else { continue }
            copy.insert(new, at: copy.pageCount)
            pages[page] = new
        }
        copy.documentAttributes = document.documentAttributes
        if let root = document.outlineRoot {
            func clone(_ item: PDFOutline) -> PDFOutline {
                let new = PDFOutline()
                new.label = item.label
                new.isOpen = item.isOpen
                if let destination = item.destination, let page = destination.page, let target = pages[page] {
                    new.destination = PDFDestination(page: target, at: destination.point)
                }
                for i in 0..<item.numberOfChildren {
                    if let child = item.child(at: i) { new.insertChild(clone(child), at: new.numberOfChildren) }
                }
                return new
            }
            copy.outlineRoot = clone(root)
        }
        return copy
    }

    /// The page, with its annotations, on white at `dpi`.
    static func render(_ page: PDFPage, dpi: Double) -> CGImage? {
        let box = page.bounds(for: .cropBox)
        let size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        let scale = dpi / 72
        let width = Int((size.width * scale).rounded(.up)), height = Int((size.height * scale).rounded(.up))
        guard width > 0, height > 0, width * height <= 400_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }
}
