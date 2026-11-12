import AppKit
import BPCore
import PDFKit

/// `BP_SYNCTEX_SELFTEST=1 BetterPreview <doc>.pdf`, where `<doc>.tex` sits
/// next to the PDF with its `.synctex.gz`, and contains lines with
/// `MARKER<p><k>` (paragraph k of the section that starts page p).
///
/// Checks forward and inverse lookups against those lines, shell quoting of
/// the editor command, a synthesized Cmd-click end to end, the URL handler,
/// `set synctex false`, and re-parsing after the SyncTeX file changes.
/// Prints PASS/FAIL lines and "SYNCTEX SELFTEST PASS|FAIL", then exits
/// (unless a BP_SCRIPT is running).
@MainActor
enum SyncTeXSelfTest {
    private static var scheduled = false

    static func scheduleIfRequested(_ feature: SyncTeXFeature) {
        guard !scheduled, ProcessInfo.processInfo.environment["BP_SYNCTEX_SELFTEST"] != nil else { return }
        scheduled = true
        let delay = Double(ProcessInfo.processInfo.environment["BP_SELFTEST_DELAY"] ?? "") ?? 1.0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak feature] in
            guard let feature else { return }
            Run(feature: feature).start()
        }
    }

    @MainActor
    private final class Run {
        let feature: SyncTeXFeature
        var ok = true
        var steps: [(Run) -> Void] = []
        /// (source line, expected 0-based page) for every MARKER line.
        var markers: [(line: Int, page: Int)] = []
        var texPath = ""
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bp-synctex-selftest-\(ProcessInfo.processInfo.processIdentifier)")

        init(feature: SyncTeXFeature) { self.feature = feature }

        var controller: PDFDocumentController { feature.controller }
        var pdfView: BPPDFView { controller.pdfView }

        func log(_ s: String) { PDFSelfTest.log(s) }
        func check(_ c: Bool, _ m: String) { ok = PDFSelfTest.check(c, "synctex: " + m) && ok }

        /// Steps run one after another; each calls `next()` when done.
        func next() {
            guard !steps.isEmpty else { return finish() }
            let step = steps.removeFirst()
            DispatchQueue.main.async { step(self) }
        }

        func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { body() } }
        }

        func start() {
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let tex = controller.fileURL.deletingPathExtension().appendingPathExtension("tex")
            texPath = tex.path
            guard let text = try? String(contentsOf: tex, encoding: .utf8) else {
                check(false, "read \(tex.path)")
                return finish()
            }
            for (i, line) in text.components(separatedBy: "\n").enumerated() {
                guard let r = line.range(of: "MARKER") else { continue }
                let digits = line[r.upperBound...].prefix(2)
                if let p = Int(digits.prefix(1)) { markers.append((i + 1, p - 1)) }
            }
            check(markers.count >= 4, "found \(markers.count) MARKER lines in the .tex")
            steps = [
                { $0.quoting() },
                { $0.lookups() },
                { $0.hugeLine() },
                { $0.urlHandler() },
                { $0.cmdClick() },
                { $0.disabled() },
                { $0.invalidation() },
            ]
            next()
        }

        // MARK: Steps

        func quoting() {
            let nasty = tmp.appendingPathComponent("a b'c\"$(echo HACK)`x`\\d.tex").path
            let source = SyncTeXSource(path: nasty, line: 42, column: 0)
            let out = tmp.appendingPathComponent("quote.txt").path
            let templates = [
                "printf '%s\\n' %{input} %{line} %{column}",
                "printf '%s\\n' \"%{input}\" \"%{line}\" '%{column}'",
                "printf '%s\\n' '%{input}' %{line}%{column}",
            ]
            let expected = [
                "\(nasty)\n42\n1\n",
                "\(nasty)\n42\n1\n",
                "\(nasty)\n421\n",
            ]
            var remaining = templates.count
            for (i, template) in templates.enumerated() {
                let file = out + "\(i)"
                let command = SyncTeXEditorCommand.expand(template, source: source) + " > " + SyncTeXEditorCommand.shellQuote(file)
                do {
                    try SyncTeXEditorCommand.run(command) { [self] status, _ in
                        let got = (try? String(contentsOfFile: file, encoding: .utf8)) ?? "<missing>"
                        check(status == 0 && got == expected[i],
                              "editor template \(i) quotes \(template.debugDescription) -> \(got.debugDescription)")
                        remaining -= 1
                        if remaining == 0 { next() }
                    }
                } catch {
                    check(false, "run editor command: \(error)")
                    remaining -= 1
                    if remaining == 0 { next() }
                }
            }
        }

        func lookups() {
            var remaining = markers.count
            let texPath = texPath
            for marker in markers {
                feature.withIndex { [self] index in
                    guard let index else {
                        check(false, "index loads")
                        return finish()
                    }
                    SyncTeXFeature.queue.async {
                        let boxes = index.boxes(sourcePath: texPath, line: marker.line, column: 0, pageHint: 0)
                        var inverse: SyncTeXSource?
                        if let box = boxes.first {
                            inverse = index.source(page: box.page, h: box.rect.midX, v: box.rect.midY)
                        }
                        DispatchQueue.main.async { [self] in
                            check(boxes.first?.page == marker.page,
                                  "forward line \(marker.line) -> page \(boxes.first.map { $0.page + 1 } ?? 0)"
                                  + " (want \(marker.page + 1)), \(boxes.count) boxes")
                            let sameFile = inverse.map { index.canonicalPath($0.path) == index.canonicalPath(texPath) }
                            check(sameFile == true && abs((inverse?.line ?? -99) - marker.line) <= 1,
                                  "inverse at box centre -> line \(inverse?.line ?? -1) (want \(marker.line) ±1)")
                            remaining -= 1
                            if remaining == 0 { next() }
                        }
                    }
                }
            }
        }

        /// Out-of-range lines and columns: no crash (Int32 overflow), no match.
        func hugeLine() {
            let bad = URLSchemeHandler.parse(URL(string: "better-preview://forward?line=0&column=-4&pdf=/tmp/x.pdf")!)
            check(bad?.line == nil && bad?.column == 0, "URL line 0 / negative column rejected \(String(describing: bad))")
            let neg = URLSchemeHandler.parse(URL(string: "better-preview://forward?line=-7&pdf=/tmp/x.pdf")!)
            check(neg?.line == nil, "URL negative line rejected")
            feature.forwardSearch(source: texPath, line: 99_999_999_999, column: 99_999_999_999) { [self] boxes in
                // Clamped to Int32.max: SyncTeX answers with the nearest line or nothing.
                check(true, "forward search with a huge line/column does not crash (\(boxes.count) boxes)")
                _ = controller.perform(ActionInvocation(.synctexForward, "99999999999:99999999999"))
                after(0.5) { [self] in
                    check(true, "synctex-forward 99999999999:99999999999 survived")
                    next()
                }
            }
        }

        func urlHandler() {
            guard let app = NSApp.delegate as? AppDelegate, let marker = markers.last else {
                check(false, "AppDelegate available")
                return next()
            }
            let parsed = URLSchemeHandler.parse(URL(string:
                "better-preview://forward?line=12&column=3&src=foo%20bar.tex&pdf=file:///tmp/x%20y.pdf")!)
            check(parsed == .init(pdf: URL(fileURLWithPath: "/tmp/x y.pdf"), source: "foo bar.tex", line: 12, column: 3),
                  "URL parsing \(String(describing: parsed))")
            // Start from the first page so the jump is visible.
            controller.show(pageAt: 0, animated: false)
            var components = URLComponents()
            components.scheme = "better-preview"
            components.host = "forward"
            components.queryItems = [
                URLQueryItem(name: "line", value: String(marker.line)),
                URLQueryItem(name: "src", value: texPath),
                URLQueryItem(name: "pdf", value: controller.fileURL.path),
            ]
            let url = components.url!
            log("synctex: handling \(url.absoluteString)")
            URLSchemeHandler.handle(url, app: app) { [self] boxes in
                check(boxes.first?.page == marker.page, "URL forward search found page \(marker.page + 1)")
                check(feature.currentFlash?.superview != nil, "flash overlay shown")
                if let flash = feature.currentFlash, let container = flash.superview {
                    check(container.subviews.last === flash && flash.frame.width > 50 && flash.frame.height > 5,
                          "flash on top of the pages, frame \(flash.frame.integral)")
                }
                after(0.8) { [self] in
                    if let flash = feature.currentFlash, let container = flash.superview {
                        check(container.visibleRect.contains(flash.frame), "flash inside the visible area")
                    }
                    check(controller.currentPageIndex == marker.page,
                          "viewport moved to page \(controller.currentPageIndex + 1) (want \(marker.page + 1))")
                    if let flash = feature.currentFlash, let viewport = controller.scroller.viewport {
                        let dy = abs(flash.frame.midY - viewport.midY)
                        check(dy < viewport.height * 0.15, "box centred (off by \(Int(dy)) pt)")
                    }
                    after(1.2) { [self] in
                        check(feature.currentFlash == nil, "flash removed itself")
                        next()
                    }
                }
            }
        }

        /// A synthesized Cmd-click on the second marker's box, end to end.
        func cmdClick() {
            let marker = markers[1]
            let out = tmp.appendingPathComponent("click.txt").path
            feature.editorCommandOverride = "printf '%s:%s' %{input} %{line} > " + SyncTeXEditorCommand.shellQuote(out)
            feature.forwardSearch(source: texPath, line: marker.line) { [self] boxes in
                guard let box = boxes.first, let page = controller.document?.page(at: box.page) else {
                    check(false, "forward search for the click target")
                    return next()
                }
                after(0.6) { [self] in
                    let media = page.bounds(for: .mediaBox)
                    let pagePoint = CGPoint(x: media.minX + box.rect.midX, y: media.maxY - box.rect.midY)
                    let windowPoint = pdfView.convert(pdfView.convert(pagePoint, from: page), to: nil)
                    let plain = mouse(.leftMouseDown, windowPoint, flags: [])
                    check(!feature.handleMouse(plain), "plain click passes through")
                    feature.onEditorCommandFinished = { [self] status, _ in
                        feature.onEditorCommandFinished = nil
                        let got = (try? String(contentsOfFile: out, encoding: .utf8)) ?? "<missing>"
                        let parts = got.split(separator: ":")
                        let line = parts.last.flatMap { Int($0) } ?? -1
                        let path = parts.dropLast().joined(separator: ":")
                        check(status == 0 && (path as NSString).lastPathComponent == (texPath as NSString).lastPathComponent
                              && abs(line - marker.line) <= 1,
                              "Cmd-click ran the editor command: \(got) (want line \(marker.line))")
                        next()
                    }
                    check(feature.handleMouse(mouse(.leftMouseDown, windowPoint, flags: .command)), "Cmd-click consumed")
                    check(feature.handleMouse(mouse(.leftMouseUp, windowPoint, flags: .command)), "its mouseUp consumed")
                    check(!feature.handleMouse(mouse(.leftMouseUp, windowPoint, flags: [])), "next mouseUp not consumed")
                }
            }
        }

        func disabled() {
            controller.host?.dispatch(ActionInvocation(.setOption, "synctex false"))
            after(0.3) { [self] in
                check(!controller.options.synctex, "set synctex false applied")
                let point = pdfView.convert(CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY), to: nil)
                check(!feature.handleMouse(mouse(.leftMouseDown, point, flags: .command)), "Cmd-click ignored when off")
                controller.host?.dispatch(ActionInvocation(.setOption, "synctex true"))
                after(0.3) { [self] in
                    check(controller.options.synctex, "set synctex true applied")
                    next()
                }
            }
        }

        func invalidation() {
            guard let file = SyncTeXIndex.synctexFile(forPDF: controller.fileURL) else { return next() }
            let before = feature.parseCount
            feature.withIndex { [self] _ in
                check(feature.parseCount == before, "cached index reused")
                try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)],
                                                       ofItemAtPath: file.path)
                feature.withIndex { [self] index in
                    check(index != nil && feature.parseCount == before + 1, "re-parsed after the file changed")
                    controller.reloadFromDisk()
                    feature.withIndex { [self] _ in
                        check(feature.parseCount == before + 2, "re-parsed after the PDF reloaded")
                        next()
                    }
                }
            }
        }

        func mouse(_ type: NSEvent.EventType, _ point: CGPoint, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: pdfView.window?.windowNumber ?? 0, context: nil,
                               eventNumber: 0, clickCount: 1, pressure: 1)!
        }

        func finish() {
            feature.editorCommandOverride = nil
            try? FileManager.default.removeItem(at: tmp)
            log("SYNCTEX SELFTEST " + (ok ? "PASS" : "FAIL"))
            if ProcessInfo.processInfo.environment["BP_SCRIPT"] == nil { exit(ok ? 0 : 1) }
        }
    }
}
