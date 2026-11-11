import AppKit
import PDFKit
import UniformTypeIdentifiers

/// File > Export: a save panel with a format popup and the options of that
/// format (resolution, quality, pages; smaller file, passwords, permissions).
@MainActor
final class ExportPanel: NSObject, NSOpenSavePanelDelegate {
    private let panel = NSSavePanel()
    private let root = NSStackView()
    private let formatPopup = NSPopUpButton()
    private let dpiField = NSTextField(string: "144")
    private let qualitySlider = NSSlider(value: 85, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let pagesPopup = NSPopUpButton()
    private let reduceCheck = NSButton(checkboxWithTitle: "Reduce file size", target: nil, action: nil)
    private let encryptCheck = NSButton(checkboxWithTitle: "Encrypt", target: nil, action: nil)
    private let openField = NSSecureTextField()
    private let verifyField = NSSecureTextField()
    private let ownerField = NSSecureTextField()
    private let printCheck = NSButton(checkboxWithTitle: "Allow printing", target: nil, action: nil)
    private let copyCheck = NSButton(checkboxWithTitle: "Allow copying text and images", target: nil, action: nil)
    private let editCheck = NSButton(checkboxWithTitle: "Allow editing", target: nil, action: nil)
    private var documentIsEncrypted = false
    private var imageRows: [NSView] = []
    private var qualityRow = NSView()
    private var pdfRows: [NSView] = []
    private var passwordRows: [NSView] = []

    /// Shows the panel (as a sheet when `window` is given). `password` is the
    /// document's own, which keeps its encryption unless unchecked.
    static func present(over window: NSWindow?, directory: URL, name: String, hasMultiplePages: Bool,
                        password: String?, documentIsEncrypted: Bool,
                        completion: @escaping (URL, PDFExportOptions) -> Void) {
        let controller = ExportPanel()
        controller.setUp(directory: directory, name: name, hasMultiplePages: hasMultiplePages, password: password,
                             documentIsEncrypted: documentIsEncrypted)
        let handle: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = controller.panel.url else { return }
            // Retains `controller` until here.
            completion(url, controller.options())
        }
        if let window {
            controller.panel.beginSheetModal(for: window) { response in MainActor.assumeIsolated { handle(response) } }
        } else {
            handle(controller.panel.runModal())
        }
    }

    private func setUp(directory: URL, name: String, hasMultiplePages: Bool, password: String?,
                       documentIsEncrypted: Bool) {
        self.documentIsEncrypted = documentIsEncrypted
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.delegate = self
        panel.message = "Export the document in another format."

        formatPopup.addItems(withTitles: PDFExportOptions.Format.allCases.map(\.title))
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged)
        dpiField.alignment = .right
        dpiField.widthAnchor.constraint(equalToConstant: 64).isActive = true
        qualitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        pagesPopup.addItems(withTitles: hasMultiplePages ? ["All pages", "Current page"] : ["Current page"])
        for field in [openField, verifyField, ownerField] {
            field.widthAnchor.constraint(equalToConstant: 160).isActive = true
        }
        for check in [printCheck, copyCheck, editCheck] { check.state = .on }
        encryptCheck.target = self
        encryptCheck.action = #selector(formatChanged)
        if documentIsEncrypted { encryptCheck.state = .on }
        if documentIsEncrypted {
            // Empty password fields keep the document's current protection.
            encryptCheck.title = "Encrypt (empty passwords keep the current ones)"
        }

        func row(_ title: String, _ views: NSView...) -> NSStackView {
            let label = NSTextField(labelWithString: title)
            label.alignment = .right
            label.widthAnchor.constraint(equalToConstant: 92).isActive = true
            let stack = NSStackView(views: [label] + views)
            stack.spacing = 8
            return stack
        }
        let formatRow = row("Format:", formatPopup)
        let dpiRow = row("Resolution:", dpiField, NSTextField(labelWithString: "pixels/inch"))
        qualityRow = row("Quality:", qualitySlider)
        let pagesRow = row("Pages:", pagesPopup)
        imageRows = [dpiRow, qualityRow, pagesRow]
        let reduceRow = row("", reduceCheck)
        let encryptRow = row("", encryptCheck)
        passwordRows = [row("Open password:", openField), row("Verify:", verifyField),
                        row("Owner password:", ownerField), row("", printCheck), row("", copyCheck), row("", editCheck)]
        pdfRows = [reduceRow, encryptRow]

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 6
        root.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        root.setViews([formatRow] + imageRows + pdfRows + passwordRows, in: .leading)
        panel.accessoryView = root
        formatChanged()
    }

    private var format: PDFExportOptions.Format {
        PDFExportOptions.Format.allCases[max(formatPopup.indexOfSelectedItem, 0)]
    }

    @objc private func formatChanged() {
        let format = format
        panel.allowedContentTypes = [format.type]
        panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension
            + "." + format.fileExtension
        imageRows.forEach { $0.isHidden = !format.isImage }
        qualityRow.isHidden = !format.supportsQuality
        pdfRows.forEach { $0.isHidden = format.isImage }
        passwordRows.forEach { $0.isHidden = format.isImage || encryptCheck.state != .on }
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
    }

    func options() -> PDFExportOptions {
        var o = PDFExportOptions()
        o.format = format
        o.dpi = Double(dpiField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 144
        o.quality = qualitySlider.doubleValue / 100
        o.currentPageOnly = pagesPopup.titleOfSelectedItem == "Current page"
        o.reduceSize = reduceCheck.state == .on
        if o.format == .pdf, documentIsEncrypted, encryptCheck.state != .on { o.stripEncryption = true }
        if o.format == .pdf, encryptCheck.state == .on {
            o.openPassword = openField.stringValue
            o.ownerPassword = ownerField.stringValue
            o.allowPrinting = printCheck.state == .on
            o.allowCopying = copyCheck.state == .on
            o.allowEditing = editCheck.state == .on
        }
        return o
    }

    // MARK: NSOpenSavePanelDelegate

    func panel(_ sender: Any, validate url: URL) throws {
        let o = options()
        if o.format == .pdf, encryptCheck.state == .on {
            if openField.stringValue != verifyField.stringValue {
                throw ExportFailure(errorDescription: "The open passwords do not match.")
            }
            if !documentIsEncrypted, o.openPassword?.isEmpty != false, o.ownerPassword?.isEmpty != false {
                throw ExportFailure(errorDescription: "Enter a password, or turn Encrypt off.")
            }
        }
        try o.validate()
    }
}
