import AppKit
import BPCore

/// Action dispatch, scrolling, frames, clipboard and printing.
extension ImageDocumentController {
    @discardableResult
    func perform(_ invocation: ActionInvocation) -> Bool {
        let count = Double(max(invocation.count ?? 1, 1))
        let argument = invocation.action.argument
        switch invocation.action.name {
        case .scrollDown: scroll(dx: 0, dy: options.scrollStep * count)
        case .scrollUp: scroll(dx: 0, dy: -options.scrollStep * count)
        case .scrollRight: scroll(dx: options.scrollHStep * count, dy: 0)
        case .scrollLeft: scroll(dx: -options.scrollHStep * count, dy: 0)
        case .scrollHalfDown: scroll(dx: 0, dy: viewportHeight * 0.5 * count)
        case .scrollHalfUp: scroll(dx: 0, dy: -viewportHeight * 0.5 * count)
        case .scrollPageDown: scroll(dx: 0, dy: viewportHeight * (1 - options.scrollPageOverlap) * count)
        case .scrollPageUp: scroll(dx: 0, dy: -viewportHeight * (1 - options.scrollPageOverlap) * count)
        case .pageNext: showFrame((requestedFrame ?? frameIndex) + Int(count))
        case .pagePrevious: showFrame((requestedFrame ?? frameIndex) - Int(count))
        case .gotoFirst: invocation.count.map { showFrame($0 - 1) } ?? gotoEdge(end: false)
        case .gotoLast: invocation.count.map { showFrame($0 - 1) } ?? gotoEdge(end: true)
        case .gotoPage:
            guard let number = argument.flatMap({ Int($0) }) ?? invocation.count else { return true }
            showFrame(number - 1)
        case .zoomIn: zoom(byFactor: pow(options.zoomStep, count))
        case .zoomOut: zoom(byFactor: pow(options.zoomStep, -count))
        case .zoomReset: setZoom(1)
        case .zoomSet:
            guard let percent = argument.flatMap({ Double($0) }) ?? invocation.count.map(Double.init) else {
                host?.showMessage("zoom-set needs a percentage", isError: true)
                return true
            }
            setZoom(percent / 100)
        case .fitPage: fit(.page)
        case .fitWidth: fit(.width)
        case .rotateCW: rotate(clockwise: true)
        case .rotateCCW: rotate(clockwise: false)
        case .imageCrop: imageCrop(argument)
        case .imageResize: imageResize(argument)
        case .imageAdjust: imageAdjust(argument)
        case .imageFlipHorizontal: flip(horizontal: true)
        case .imageFlipVertical: flip(horizontal: false)
        case .export: export(argument)
        case .abort: cancelCrop()
        case .copy: copyToPasteboard()
        case .print: printImage()
        case .reload: reloadFromDisk()
        default: return false
        }
        return true
    }

    private var viewportHeight: Double { scrollView.contentView.frame.height }

    /// Scrolls by view points (positive = down / right).
    private func scroll(dx: Double, dy: Double) {
        scroller.scroll(by: CGVector(dx: dx / zoom, dy: dy / zoom))
    }

    /// Single image: top or bottom edge of the view.
    private func gotoEdge(end: Bool) {
        if model.frameCount > 1 {
            showFrame(end ? model.frameCount - 1 : 0)
            return
        }
        guard let origin = scroller.destination else { return }
        let height = canvas.frame.height
        scroller.jump(to: CGPoint(x: origin.x, y: end ? height : 0))
    }

    /// Switches to another frame of a multi-frame file (clamped). The shown
    /// frame's edits are kept (see `frameEdits`); `frameIndex` changes when
    /// the new frame is decoded, so edits until then apply to the shown one.
    func showFrame(_ index: Int) {
        let clamped = min(max(index, 0), model.frameCount - 1)
        guard clamped != (requestedFrame ?? frameIndex) else { return }
        if clamped == frameIndex {
            // Back to the shown frame before the switch finished.
            requestedFrame = nil
            decodeGeneration += 1
            return
        }
        requestedFrame = clamped
        decodeFrame(clamped)
        scheduleStatusUpdate()
    }

    // MARK: Clipboard and printing

    /// The best bitmap available: huge images are decoded in full for copying.
    private func bestImage() -> CGImage? {
        if model.isDownsampled, model.fullResolution == nil, model.pendingEdit == nil,
           let loaded = ImageLoader.load(originalURL, index: frameIndex, displayMax: 0, full: true) {
            return loaded.image
        }
        return model.displayImage
    }

    private func copyToPasteboard() {
        guard let cgImage = bestImage() else { return }
        let image = NSImage(cgImage: cgImage, size: model.pixelSize)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        host?.showMessage("Copied image", isError: false)
    }

    /// Prints the image scaled down to fit one page, centred.
    private func printImage() {
        guard let cgImage = bestImage() else { return }
        let size = model.physicalSize
        let imageView = NSImageView(frame: CGRect(origin: .zero, size: size))
        imageView.image = NSImage(cgImage: cgImage, size: size)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        guard let info = NSPrintInfo.shared.copy() as? NSPrintInfo else { return }
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let operation = NSPrintOperation(view: imageView, printInfo: info)
        if let window = view.window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
