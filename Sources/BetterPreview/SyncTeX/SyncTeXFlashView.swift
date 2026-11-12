import AppKit

/// A short-lived highlight over the boxes a forward search found. Lives in
/// the PDF document view (so it scrolls with the page), never takes mouse
/// events, fades out and removes itself. Nothing is written to the PDF.
@MainActor
final class SyncTeXFlashView: NSView {
    private static let hold: TimeInterval = 0.7
    private static let fade: TimeInterval = 0.6

    /// `rects` are in `container`'s coordinates.
    static func flash(_ rects: [CGRect], in container: NSView, color: NSColor) -> SyncTeXFlashView? {
        let padded = rects.map { $0.insetBy(dx: -2, dy: -2) }
        guard let first = padded.first else { return nil }
        let frame = padded.dropFirst().reduce(first) { $0.union($1) }
        let view = SyncTeXFlashView(frame: frame)
        container.addSubview(view)
        view.show(padded.map { view.convert($0, from: container) }, color: color)
        return view
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    private func show(_ rects: [CGRect], color: NSColor) {
        guard let layer else { return }
        for rect in rects {
            let box = CALayer()
            box.frame = rect
            box.cornerRadius = 3
            box.backgroundColor = color.withAlphaComponent(0.28).cgColor
            box.borderColor = color.withAlphaComponent(0.9).cgColor
            box.borderWidth = 1.5
            layer.addSublayer(box)
        }
        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        let total = Self.hold + Self.fade
        pulse.values = [0, 1, 1, 0]
        pulse.keyTimes = [0, NSNumber(value: 0.12 / total), NSNumber(value: Self.hold / total), 1]
        pulse.duration = total
        layer.opacity = 0
        layer.add(pulse, forKey: "flash")
        DispatchQueue.main.asyncAfter(deadline: .now() + total) { [weak self] in
            self?.removeFromSuperview()
        }
    }
}
