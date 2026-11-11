import AppKit
import PDFKit

/// Saving, exporting and the encryption that goes with them.
extension PDFDocumentController {
    /// Writes the document in place (nil) or as a copy. Atomic; read-only
    /// files and missing folders are refused with a readable error.
    func savePDF(to url: URL?) throws {
        guard let document else { return }
        let destination = url ?? fileURL
        let inPlace = destination.standardizedFileURL == fileURL.standardizedFileURL
        // A file that went away is simply written again. PDFKit keeps the
        // encryption (passwords and permissions) of an unlocked document.
        try withPristinePages { try PDFExporter.writePDF(document, to: destination, options: PDFExportOptions()) }
        if inPlace { isDirty = false }
    }

    // MARK: Export

    /// `export` without arguments shows the panel; with a path it writes
    /// there (see `ExportRequest` for the options).
    func export(_ argument: String?) {
        let request: ExportRequest
        do { request = try ExportRequest.parse(argument) } catch {
            host?.showMessage(error.localizedDescription, isError: true)
            return
        }
        guard let path = request.path else { return presentExportPanel() }
        let expanded = (path as NSString).expandingTildeInPath
        let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded)
            : fileURL.deletingLastPathComponent().appendingPathComponent(expanded)).standardizedFileURL
        guard let document else { return }
        let targets = PDFExporter.targets(for: document, currentPage: currentPageIndex, url: url,
                                          options: request.options)
        if targets.contains(where: { $0.standardizedFileURL == fileURL.standardizedFileURL }) {
            return host?.showMessage("export: that is the open file; use save", isError: true) ?? ()
        }
        let existing = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !request.force, let first = existing.first {
            let more = existing.count > 1 ? " and \(existing.count - 1) more" : ""
            return host?.showMessage("export: \(first.lastPathComponent)\(more) exists (add \"force\" to replace)",
                                     isError: true) ?? ()
        }
        runExport(to: url, options: request.options)
    }

    private func presentExportPanel() {
        let count = document?.pageCount ?? 0
        ExportPanel.present(over: pdfView.window, directory: fileURL.deletingLastPathComponent(),
                            name: fileURL.deletingPathExtension().lastPathComponent, hasMultiplePages: count > 1,
                            password: document?.isEncrypted == true ? documentPassword : nil,
                            documentIsEncrypted: document?.isEncrypted == true) { [weak self] url, options in
            self?.confirmAndExport(to: url, options: options)
        }
    }

    /// The panel asked about `url` itself; one image per page writes other
    /// names, so ask once before replacing any of those.
    private func confirmAndExport(to url: URL, options: PDFExportOptions) {
        guard let document else { return }
        let targets = PDFExporter.targets(for: document, currentPage: currentPageIndex, url: url, options: options)
        if targets.contains(where: { $0.standardizedFileURL == fileURL.standardizedFileURL }) {
            return host?.showMessage("export: that is the open file; use save", isError: true) ?? ()
        }
        let existing = targets.count > 1 ? targets.filter { FileManager.default.fileExists(atPath: $0.path) } : []
        guard let first = existing.first, let window = pdfView.window else {
            return runExport(to: url, options: options)
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = existing.count == 1 ? "“\(first.lastPathComponent)” already exists. Replace it?"
            : "\(existing.count) files like “\(first.lastPathComponent)” already exist. Replace them?"
        alert.informativeText = "Exporting one image per page writes \(targets.count) files."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        // The export panel's sheet is still closing; wait for it.
        DispatchQueue.main.async { [weak self] in
            alert.beginSheetModal(for: window) { response in
                guard response == .alertFirstButtonReturn else { return }
                self?.runExport(to: url, options: options)
            }
        }
    }

    func runExport(to url: URL, options: PDFExportOptions) {
        guard let document else { return }
        if PDFExporter.changesEncryption(options),
           !PasswordPrompt.ensureOwnerAccess(document, fileName: fileURL.lastPathComponent) {
            return host?.showMessage("export: the document's owner restricts it; removing or changing its "
                                     + "encryption needs the owner password", isError: true) ?? ()
        }
        do {
            let written = try withPristinePages {
                try PDFExporter.export(document, currentPage: currentPageIndex, to: url, options: options)
            }
            host?.showMessage(written.count == 1 ? "exported \(url.path)"
                              : "exported \(written.count) files to \(url.deletingLastPathComponent().path)",
                              isError: false)
        } catch {
            host?.showMessage("export: \(error.localizedDescription)", isError: true)
        }
    }
}
