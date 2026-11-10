import AppKit
import BPCore
import PDFKit

/// Placing, selecting, moving, resizing and deleting signature stamps.
extension FormsFeature {
    // MARK: Placing

    func placeSignature(named query: String?) {
        let store = SignatureStore.shared
        let all = store.list()
        let name = query?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty {
            guard let entry = store.entry(named: name) else {
                controller.host?.showMessage("No signature named \"\(name)\"", isError: true)
                return
            }
            place(entry)
        } else if all.isEmpty {
            controller.host?.showMessage("No signatures yet: create one first", isError: false)
            SignatureManager.shared.show(for: self)
        } else if let last = lastUsedSignature, let entry = store.entry(named: last) {
            place(entry)
        } else if all.count == 1 {
            place(all[0])
        } else {
            let menu = NSMenu()
            for entry in all {
                let item = NSMenuItem(title: entry.name, action: #selector(menuPick(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.name
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let manage = NSMenuItem(title: "Manage Signatures…", action: #selector(menuManage), keyEquivalent: "")
            manage.target = self
            menu.addItem(manage)
            menu.popUp(positioning: nil, at: NSPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), in: pdfView)
        }
    }

    @objc private func menuPick(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String, let entry = SignatureStore.shared.entry(named: name) {
            place(entry)
        }
    }

    @objc private func menuManage() { SignatureManager.shared.show(for: self) }

    /// Places `entry` at the centre of the viewport (or `page`/`point`).
    @discardableResult
    func place(_ entry: SignatureStore.Entry, on page: PDFPage? = nil, at point: CGPoint? = nil) -> SignatureAnnotation? {
        guard let image = SignatureStore.shared.image(for: entry) else {
            controller.host?.showMessage("Cannot read signature \"\(entry.name)\"", isError: true)
            return nil
        }
        var target = page
        var center = point
        if target == nil {
            let c = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
            target = pdfView.page(for: c, nearest: true) ?? pdfView.currentPage ?? pdfView.document?.page(at: 0)
            if let t = target, pdfView.bounds.width > 1 { center = pdfView.convert(c, to: t) }
        }
        guard let target else { return nil }
        let box = target.bounds(for: .cropBox)
        let center2 = center ?? CGPoint(x: box.midX, y: box.midY)
        let aspect = CGFloat(image.width) / CGFloat(max(image.height, 1))
        var width = min(box.width * 0.3, 220)
        var height = width / aspect
        if height > box.height * 0.2 {
            height = box.height * 0.2
            width = height * aspect
        }
        var origin = CGPoint(x: center2.x - width / 2, y: center2.y - height / 2)
        origin.x = min(max(origin.x, box.minX), max(box.minX, box.maxX - width))
        origin.y = min(max(origin.y, box.minY), max(box.minY, box.maxY - height))
        let annotation = SignatureAnnotation(image: image, bounds: CGRect(origin: origin, size: CGSize(width: width, height: height)),
                                             name: entry.name, renderState: controller.renderState)
        annotation.viewScale = pdfView.scaleFactor
        lastUsedSignature = entry.name
        addSignature(annotation, to: target)
        select(annotation)
        return annotation
    }

    // MARK: Add, remove, move (all undoable)

    func addSignature(_ annotation: SignatureAnnotation, to page: PDFPage) {
        page.addAnnotation(annotation)
        placed.append(annotation)
        pdfView.annotationsChanged(on: page)
        controller.isDirty = true
        controller.undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.removeSignature(annotation) }
        }
        if !controller.undoManager.isUndoing { controller.undoManager.setActionName("Place Signature") }
    }

    func removeSignature(_ annotation: SignatureAnnotation) {
        guard let page = annotation.page else { return }
        if selected === annotation { select(nil) }
        page.removeAnnotation(annotation)
        placed.removeAll { $0 === annotation }
        pdfView.annotationsChanged(on: page)
        controller.isDirty = true
        controller.undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.addSignature(annotation, to: page) }
        }
        if !controller.undoManager.isUndoing { controller.undoManager.setActionName("Delete Signature") }
    }

    func setBounds(_ new: CGRect, of annotation: SignatureAnnotation) {
        let old = annotation.bounds
        annotation.bounds = new
        if let page = annotation.page { pdfView.annotationsChanged(on: page) }
        controller.isDirty = true
        controller.undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.setBounds(old, of: annotation) }
        }
        if !controller.undoManager.isUndoing { controller.undoManager.setActionName("Move Signature") }
    }

    func select(_ annotation: SignatureAnnotation?) {
        guard selected !== annotation else { return }
        let previous = selected
        selected = annotation
        previous?.isSelected = false
        annotation?.isSelected = true
        annotation?.viewScale = pdfView.scaleFactor
        for a in [previous, annotation] {
            if let page = a?.page { pdfView.annotationsChanged(on: page) }
        }
        controller.scheduleStatusUpdate()
    }

    // MARK: Mouse (free when no signature was placed)

    func signatureMouseDown(_ event: NSEvent) -> Bool {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else {
            select(nil)
            return false
        }
        adoptSavedSignatures(on: page)
        guard !placed.isEmpty else { return false }
        let point = pdfView.convert(viewPoint, to: page)
        let scale = max(pdfView.scaleFactor, 0.05)

        if let current = selected, current.page === page {
            let size = SignatureAnnotation.handleSize / scale + 4 / scale
            for (i, rect) in SignatureAnnotation.corners(of: current.bounds, size: size).enumerated()
            where rect.insetBy(dx: -2, dy: -2).contains(point) {
                drag = .resize(corner: i, startBounds: current.bounds)
                dragOriginalBounds = current.bounds
                return true
            }
        }
        if let hit = placed.last(where: { $0.page === page && $0.bounds.contains(point) }) {
            select(hit)
            drag = .move(startPoint: point, startBounds: hit.bounds)
            dragOriginalBounds = hit.bounds
            return true
        }
        select(nil)
        return false
    }

    // MARK: Signatures saved earlier

    /// Signatures written by this app come back from the file as plain Stamp
    /// annotations ("Signature" by "Better Preview"). The ones on `page` are
    /// turned back into `SignatureAnnotation`s, drawn from their saved
    /// appearance, so they can be selected, moved, resized and deleted again.
    /// Each page is searched once; this is not an edit (no undo, not dirty).
    func adoptSavedSignatures(on page: PDFPage) {
        guard !adoptedPages.contains(page) else { return }
        adoptedPages.add(page)
        for annotation in page.annotations where Self.isSavedSignature(annotation) {
            guard let image = Self.image(of: annotation) else { continue }
            let signature = SignatureAnnotation(image: image, bounds: annotation.bounds, name: "",
                                                renderState: controller.renderState)
            signature.viewScale = pdfView.scaleFactor
            page.removeAnnotation(annotation)
            page.addAnnotation(signature)
            placed.append(signature)
        }
    }

    static func isSavedSignature(_ annotation: PDFAnnotation) -> Bool {
        !(annotation is SignatureAnnotation) && annotation.type == "Stamp"
            && annotation.contents == "Signature" && annotation.userName == "Better Preview"
    }

    /// Renders an annotation's appearance at up to 4x (2400 px at most).
    static func image(of annotation: PDFAnnotation) -> CGImage? {
        let bounds = annotation.bounds
        guard bounds.width >= 1, bounds.height >= 1 else { return nil }
        let scale = min(4, 2400 / max(bounds.width, bounds.height))
        let width = Int((bounds.width * scale).rounded(.up)), height = Int((bounds.height * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        annotation.draw(with: .mediaBox, in: context)
        return context.makeImage()
    }

    func signatureMouseDragged(_ event: NSEvent) -> Bool {
        guard let annotation = selected, let page = annotation.page, let drag else { return false }
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        let point = pdfView.convert(viewPoint, to: page)
        let box = page.bounds(for: .cropBox)
        switch drag {
        case .move(let start, let startBounds):
            var origin = CGPoint(x: startBounds.minX + point.x - start.x, y: startBounds.minY + point.y - start.y)
            origin.x = min(max(origin.x, box.minX - startBounds.width * 0.8), box.maxX - startBounds.width * 0.2)
            origin.y = min(max(origin.y, box.minY - startBounds.height * 0.8), box.maxY - startBounds.height * 0.2)
            annotation.bounds = CGRect(origin: origin, size: startBounds.size)
        case .resize(let corner, let b):
            // Corners: 0 bottom-left, 1 bottom-right, 2 top-left, 3 top-right.
            let anchor = CGPoint(x: corner % 2 == 0 ? b.maxX : b.minX, y: corner < 2 ? b.maxY : b.minY)
            let aspect = annotation.aspect
            var width = max(abs(point.x - anchor.x), 14)
            var height = width / aspect
            // Follow whichever axis the pointer moved further along.
            if abs(point.y - anchor.y) > height {
                height = abs(point.y - anchor.y)
                width = height * aspect
            }
            let x = corner % 2 == 0 ? anchor.x - width : anchor.x
            let y = corner < 2 ? anchor.y - height : anchor.y
            annotation.bounds = CGRect(x: x, y: y, width: width, height: height)
        }
        pdfView.annotationsChanged(on: page)
        return true
    }

    func signatureMouseUp(_ event: NSEvent) -> Bool {
        defer {
            drag = nil
            dragOriginalBounds = nil
        }
        guard let annotation = selected, let original = dragOriginalBounds else { return true }
        let final = annotation.bounds
        if final != original {
            annotation.bounds = original
            setBounds(final, of: annotation)
        }
        return true
    }
}
