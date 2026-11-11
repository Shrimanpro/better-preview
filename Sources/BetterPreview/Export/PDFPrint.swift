import AppKit
import PDFKit

/// How pages are fitted to the paper.
final class PrintSettings: NSObject {
    enum Scaling: Int {
        case fit, shrinkToFit, actualSize
        static let titles = ["Scale to fit page", "Shrink oversized pages only", "Actual size"]
    }

    var scaling = Scaling.fit
    var autoRotate = true
}

/// Print panel accessory: scaling and automatic rotation. Page range, copies,
/// paper size and orientation are the standard panel's.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let settings: PrintSettings
    private let popup = NSPopUpButton()
    private let rotate = NSButton(checkboxWithTitle: "Rotate pages to fit the paper", target: nil, action: nil)

    init(settings: PrintSettings) {
        self.settings = settings
        super.init(nibName: nil, bundle: nil)
        title = "Better Preview"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        popup.addItems(withTitles: PrintSettings.Scaling.titles)
        popup.selectItem(at: settings.scaling.rawValue)
        popup.target = self
        popup.action = #selector(changed)
        rotate.state = settings.autoRotate ? .on : .off
        rotate.target = self
        rotate.action = #selector(changed)
        let label = NSTextField(labelWithString: "Scaling:")
        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        let stack = NSStackView(views: [row, rotate])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.frame = CGRect(origin: .zero, size: stack.fittingSize)
        view = stack
    }

    @objc private func changed() {
        settings.scaling = PrintSettings.Scaling(rawValue: popup.indexOfSelectedItem) ?? .fit
        settings.autoRotate = rotate.state == .on
        willChangeValue(forKey: "printSettings")
        didChangeValue(forKey: "printSettings")
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Scaling", .itemDescription: PrintSettings.Scaling.titles[settings.scaling.rawValue]]]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> { ["printSettings"] }
    @objc dynamic var printSettings: Int { settings.scaling.rawValue }
}

/// Draws a pristine copy of the document, one sheet per page, honouring the
/// page range, paper size and orientation the print panel settled on.
final class PDFPrintView: NSView {
    private let document: PDFDocument
    private let settings: PrintSettings
    private var cell = NSSize(width: 612, height: 792)

    init(document: PDFDocument, settings: PrintSettings) {
        self.document = document
        self.settings = settings
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792 * CGFloat(max(document.pageCount, 1))))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func updateLayout() {
        let info = NSPrintOperation.current?.printInfo ?? NSPrintInfo.shared
        let paper = info.paperSize
        cell = NSSize(width: max(1, paper.width - info.leftMargin - info.rightMargin),
                      height: max(1, paper.height - info.topMargin - info.bottomMargin))
        setFrameSize(NSSize(width: cell.width, height: cell.height * CGFloat(max(document.pageCount, 1))))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        updateLayout()
        range.pointee = NSRange(location: 1, length: document.pageCount)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * cell.height, width: cell.width, height: cell.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, cell.height > 0 else { return }
        let first = max(0, Int(dirtyRect.minY / cell.height))
        let last = min(document.pageCount - 1, Int((dirtyRect.maxY - 0.5) / cell.height))
        guard first <= last else { return }
        for index in first...last {
            guard let page = document.page(at: index) else { continue }
            draw(page, in: rectForPage(index + 1), context: context)
        }
    }

    private func draw(_ page: PDFPage, in rect: NSRect, context: CGContext) {
        let box = page.bounds(for: .cropBox)
        var size = page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        guard size.width > 0, size.height > 0 else { return }
        let rotate = settings.autoRotate && (size.width > size.height) != (rect.width > rect.height)
        if rotate { size = CGSize(width: size.height, height: size.width) }
        let fit = min(rect.width / size.width, rect.height / size.height)
        let scale: CGFloat
        switch settings.scaling {
        case .fit: scale = fit
        case .shrinkToFit: scale = min(1, fit)
        case .actualSize: scale = 1
        }
        context.saveGState()
        context.clip(to: rect)
        // Bottom-left of the placed page, y up, scaled to points on paper.
        context.translateBy(x: rect.minX + (rect.width - size.width * scale) / 2,
                            y: rect.minY + (rect.height + size.height * scale) / 2)
        context.scaleBy(x: scale, y: -scale)
        if rotate {
            context.translateBy(x: size.width, y: 0)
            context.rotate(by: .pi / 2)
        }
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}

extension PDFDocumentController {
    /// The print operation for a pristine copy of the document.
    func makePrintOperation(copy: PDFDocument, info: NSPrintInfo, settings: PrintSettings) -> NSPrintOperation {
        let view = PDFPrintView(document: copy, settings: settings)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = fileURL.lastPathComponent
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let panel = operation.printPanel
        panel.options = [.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation,
                         .showsScaling, .showsPreview]
        panel.addAccessoryController(PrintAccessoryController(settings: settings))
        return operation
    }

    /// A copy of the document as the file has it: no view rotation, trim or
    /// recolor, annotations included. The print sheet renders after this
    /// returns, when the view's own state is back in place.
    func pristineCopy() -> PDFDocument? {
        guard let data = withPristinePages({ document?.dataRepresentation() }),
              let copy = PDFDocument(data: data) else { return nil }
        if copy.isLocked, let documentPassword { copy.unlock(withPassword: documentPassword) }
        return copy.isLocked ? nil : copy
    }

    func printDocument() {
        guard let document, document.allowsPrinting else {
            host?.showMessage("print: this document does not allow printing", isError: true)
            return
        }
        guard let copy = pristineCopy() else {
            host?.showMessage("print: could not prepare the document", isError: true)
            return
        }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        let operation = makePrintOperation(copy: copy, info: info, settings: PrintSettings())
        if let window = pdfView.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
