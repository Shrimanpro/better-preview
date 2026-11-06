import AppKit
import QuartzCore

/// Paints the paper PDFKit shows behind not-yet-rendered tiles in the
/// recolor paper colour, so fast scrolling with recolor on does not flash
/// white.
///
/// macOS 27 PDFKit gives every visible page a `PDFPageLayer` whose sublayer
/// named "backgroundLayer" is filled opaque white under the tile layers. That
/// layer is private, so it is found defensively: layers whose class is named
/// `PDFPageLayer`, within a few levels of the clip view's layer, each with a
/// direct sublayer named `backgroundLayer`. Only its `backgroundColor` is
/// changed, through public CALayer API. If the structure is not found exactly
/// like that, nothing is touched.
///
/// PDFKit creates page layers as pages scroll into view, so while a colour is
/// set a run-loop observer re-checks the (few) visible page layers once per
/// run-loop turn, before Core Animation commits. Walking 2-6 layers costs
/// microseconds, and the observer only fires when the run loop wakes, so an
/// idle window does no work. With no colour set there is no observer at all.
@MainActor
final class TileBackdrop {
    private weak var pdfView: BPPDFView?
    private var observer: CFRunLoopObserver?
    /// The paper colour to show, nil for PDFKit's own (white).
    private(set) var color: CGColor?
    /// Page background layers we recoloured, to restore when turned off.
    private let painted = NSHashTable<CALayer>.weakObjects()
    private struct Watch {
        weak var layer: CALayer?
        let observation: NSKeyValueObservation
    }
    private var watches: [ObjectIdentifier: Watch] = [:]
    /// Sublayer watches of the clip view's layer and the document layer.
    private var containerWatches: [ObjectIdentifier: Watch] = [:]
    #if DEBUG
    private var loggedColor: CGColor?
    private var loggedNotFound = false
    /// Page layers found already committed with PDFKit's white.
    private(set) var lateCount = 0
    private static let verbose = ProcessInfo.processInfo.environment["BP_SCROLL_STATS"] == "1"
        || ProcessInfo.processInfo.environment["BP_TILE_DEBUG"] == "1"
    #endif

    init(pdfView: BPPDFView) {
        self.pdfView = pdfView
    }

    /// Sets the paper colour (nil restores PDFKit's white).
    func setColor(_ new: CGColor?) {
        guard new != color else { return }
        color = new
        if new == nil {
            removeObserver()
            restore()
        } else {
            installObserver()
            apply()
        }
    }

    /// Re-checks the page layers now (after a layout the caller forced).
    func refresh() {
        apply()
    }

    /// Stops observing; call when the view goes away.
    func invalidate() {
        removeObserver()
        stopWatching()
    }

    // MARK: Layers

    private func installObserver() {
        guard observer == nil else { return }
        // Just before Core Animation's commit observer (order 2000000).
        let observer = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_000
        ) { [weak self] observer, _ in
            MainActor.assumeIsolated {
                // The owner is gone (window closed): remove ourselves.
                guard let self else { return CFRunLoopObserverInvalidate(observer) }
                self.apply()
            }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    private func removeObserver() {
        guard let observer else { return }
        CFRunLoopObserverInvalidate(observer)
        self.observer = nil
    }

    /// The page background layers currently in the view, or nil when the
    /// layer tree does not look as expected.
    private func backgroundLayers() -> [CALayer]? {
        guard let root = pdfView?.enclosedScrollView?.contentView.layer else { return nil }
        var pages: [CALayer] = []
        var containers: [CALayer] = []
        func collect(_ layer: CALayer, depth: Int) {
            // The clip view's layer and the document layer under it.
            if depth < 2 { containers.append(layer) }
            guard depth < 4, let sublayers = layer.sublayers else { return }
            for sublayer in sublayers {
                if NSStringFromClass(type(of: sublayer)) == "PDFPageLayer" {
                    pages.append(sublayer)
                } else {
                    collect(sublayer, depth: depth + 1)
                }
            }
        }
        collect(root, depth: 0)
        watchContainers(containers)
        guard !pages.isEmpty else { return nil }
        var result: [CALayer] = []
        for page in pages {
            guard let background = page.sublayers?.first(where: { $0.name == "backgroundLayer" }),
                  type(of: background) == CALayer.self else { return nil }
            result.append(background)
        }
        return result
    }

    /// PDFKit adds page layers (and, after a reload or layout change, new
    /// document layers) inside Core Animation's commit. Watching the
    /// containers' sublayers catches them as they are added, before they are
    /// ever shown white; the run-loop observer would be one frame late.
    private func watchContainers(_ containers: [CALayer]) {
        let ids = Set(containers.map(ObjectIdentifier.init))
        for (id, watch) in containerWatches where !ids.contains(id) || watch.layer == nil {
            watch.observation.invalidate()
            containerWatches[id] = nil
        }
        // (Identity check too: a new layer can reuse a freed one's address.)
        for container in containers where containerWatches[ObjectIdentifier(container)]?.layer !== container {
            containerWatches[ObjectIdentifier(container)]?.observation.invalidate()
            let observation = container.observe(\.sublayers) { [weak self] _, _ in
                guard Thread.isMainThread else { return }
                MainActor.assumeIsolated { self?.apply() }
            }
            containerWatches[ObjectIdentifier(container)] = Watch(layer: container, observation: observation)
        }
    }

    private func apply() {
        guard let color else { return }
        guard let layers = backgroundLayers() else {
            #if DEBUG
            if Self.verbose, !loggedNotFound {
                loggedNotFound = true
                log("TILEBACKDROP not-found yet (no change made)")
            }
            #endif
            return
        }
        var live = Set<ObjectIdentifier>()
        for layer in layers {
            let id = ObjectIdentifier(layer)
            live.insert(id)
            if layer.backgroundColor != color {
                #if DEBUG
                // A presentation copy exists once the layer has been
                // committed: then it was on screen white for a frame.
                if Self.verbose, layer.presentation() != nil,
                   layer.backgroundColor == CGColor(gray: 1, alpha: 1) { lateCount += 1 }
                #endif
                paint(layer, color)
            }
            if watches[id]?.layer !== layer {
                watches[id]?.observation.invalidate()
                // PDFKit resets the colour while it lays pages out (inside
                // Core Animation's commit); put ours back the moment it does.
                let observation = layer.observe(\.backgroundColor) { [weak self] layer, _ in
                    guard Thread.isMainThread else { return }
                    MainActor.assumeIsolated {
                        guard let self, let color = self.color, layer.backgroundColor != color else { return }
                        self.paint(layer, color)
                    }
                }
                watches[id] = Watch(layer: layer, observation: observation)
            }
        }
        // Forget layers PDFKit has dropped.
        for (id, watch) in watches where !live.contains(id) || watch.layer == nil {
            watch.observation.invalidate()
            watches[id] = nil
        }
        #if DEBUG
        if Self.verbose, loggedColor != color {
            let verified = layers.allSatisfy { $0.backgroundColor == color }
            log("TILEBACKDROP applied pages=\(layers.count) verified=\(verified) color=\(color.components ?? [])")
            loggedColor = color
        }
        #endif
    }

    private func paint(_ layer: CALayer, _ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = color
        CATransaction.commit()
        painted.add(layer)
    }

    private func stopWatching() {
        for watch in watches.values { watch.observation.invalidate() }
        watches.removeAll()
        for watch in containerWatches.values { watch.observation.invalidate() }
        containerWatches.removeAll()
    }

    private func restore() {
        stopWatching()
        #if DEBUG
        if Self.verbose { log("TILEBACKDROP late=\(lateCount)") }
        lateCount = 0
        #endif
        let white = CGColor(gray: 1, alpha: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in painted.allObjects { layer.backgroundColor = white }
        CATransaction.commit()
        painted.removeAllObjects()
        #if DEBUG
        if Self.verbose { log("TILEBACKDROP restored") }
        loggedColor = nil
        #endif
    }

    #if DEBUG
    private func log(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
    #endif
}
