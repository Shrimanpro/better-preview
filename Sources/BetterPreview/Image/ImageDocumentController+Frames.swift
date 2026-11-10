import ImageIO
import UniformTypeIdentifiers

/// Multi-frame files: edits are kept per frame (`frameEdits` plus the shown
/// frame's `model.pendingEdit`), and saving in the file's own format writes
/// every frame, the edited ones re-encoded and the rest copied unchanged.
extension ImageDocumentController {
    /// The frames to write with the shown one, or nil for a single-frame
    /// write (single-frame files, or a format other than the file's: an
    /// export to PNG/JPEG writes the shown frame only).
    func frameSet(for type: UTType) -> ImageEncoder.FrameSet? {
        guard model.frameCount > 1, let sourceType = model.sourceType, type == sourceType,
              let source = ImageLoader.source(originalURL), CGImageSourceGetCount(source) == model.frameCount
        else { return nil }
        return ImageEncoder.FrameSet(source: source, index: frameIndex, edits: frameEdits)
    }

    /// Frames with unsaved-or-saved edits other than the shown one (self-test).
    var editedOtherFrames: [Int] { frameEdits.keys.sorted() }
}
