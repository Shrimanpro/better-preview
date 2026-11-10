import AppKit
import UniformTypeIdentifiers

/// Resize sheet: width, height, keep aspect, percent.
@MainActor
final class ResizeForm: NSObject, NSTextFieldDelegate {
    let view = NSStackView()
    private let width = NSTextField(), height = NSTextField(), percent = NSTextField()
    private let keepAspect = NSButton(checkboxWithTitle: "Keep aspect ratio", target: nil, action: nil)
    private let original: CGSize

    init(size: CGSize) {
        original = size
        super.init()
        func row(_ title: String, _ field: NSTextField, _ unit: String) -> NSStackView {
            field.delegate = self
            field.alignment = .right
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 56).isActive = true
            return NSStackView(views: [label, field, NSTextField(labelWithString: unit)])
        }
        width.stringValue = "\(Int(size.width))"
        height.stringValue = "\(Int(size.height))"
        percent.stringValue = "100"
        keepAspect.state = .on
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        view.setViews([row("Width", width, "px"), row("Height", height, "px"), row("Scale", percent, "%"), keepAspect],
                      in: .leading)
        view.frame = CGRect(x: 0, y: 0, width: 220, height: 110)
    }

    var result: (Int, Int)? {
        guard let w = Int(width.stringValue), let h = Int(height.stringValue), w > 0, h > 0 else { return nil }
        return (w, h)
    }

    func controlTextDidChange(_ note: Notification) {
        guard let field = note.object as? NSTextField else { return }
        let keep = keepAspect.state == .on
        if field === percent, let p = Double(percent.stringValue), p > 0 {
            width.stringValue = "\(max(1, Int((original.width * p / 100).rounded())))"
            height.stringValue = "\(max(1, Int((original.height * p / 100).rounded())))"
        } else if field === width, keep, let w = Double(width.stringValue) {
            height.stringValue = "\(max(1, Int((w * original.height / original.width).rounded())))"
            percent.stringValue = String(format: "%.0f", w / original.width * 100)
        } else if field === height, keep, let h = Double(height.stringValue) {
            width.stringValue = "\(max(1, Int((h * original.width / original.height).rounded())))"
            percent.stringValue = String(format: "%.0f", h / original.height * 100)
        }
    }
}

/// Export panel accessory: format popup and quality slider.
@MainActor
final class ExportAccessory: NSObject {
    let view = NSStackView()
    private let popup = NSPopUpButton()
    private let slider = NSSlider(value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: "Quality")
    private weak var panel: NSSavePanel?

    var type: UTType { ImageEncoder.exportFormats[max(popup.indexOfSelectedItem, 0)].type }
    var quality: Double { slider.doubleValue / 100 }

    init(panel: NSSavePanel, initial: UTType?) {
        self.panel = panel
        super.init()
        popup.addItems(withTitles: ImageEncoder.exportFormats.map(\.name))
        if let initial, let i = ImageEncoder.exportFormats.firstIndex(where: { initial.conforms(to: $0.type) }) {
            popup.selectItem(at: i)
        }
        popup.target = self
        popup.action = #selector(formatChanged)
        view.orientation = .horizontal
        view.spacing = 8
        view.setViews([NSTextField(labelWithString: "Format"), popup, qualityLabel, slider], in: .leading)
        slider.widthAnchor.constraint(equalToConstant: 120).isActive = true
        view.frame = CGRect(x: 0, y: 0, width: 420, height: 32)
        formatChanged()
    }

    @objc private func formatChanged() {
        let type = type
        let hide = !ImageEncoder.supportsQuality(type)
        slider.isHidden = hide
        qualityLabel.isHidden = hide
        panel?.allowedContentTypes = [type]
        if let panel, let ext = type.preferredFilenameExtension {
            panel.nameFieldStringValue = (panel.nameFieldStringValue as NSString).deletingPathExtension + "." + ext
        }
    }
}
