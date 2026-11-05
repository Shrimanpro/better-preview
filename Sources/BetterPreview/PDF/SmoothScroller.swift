import AppKit
import QuartzCore

/// Keyboard-driven smooth scrolling of an NSScrollView, shared by the PDF
/// and image viewers.
///
/// All points are in the clip view's bounds coordinates (the document view's
/// coordinate space; for PDFKit that space is independent of zoom and y
/// grows down).
///
/// The visible origin follows a critically damped spring toward `target`,
/// integrated in closed form once per display refresh from a display link that
/// exists only while moving. A new scroll mid-flight adds to the target and
/// keeps the current velocity. While scrolls arrive at key-repeat cadence the
/// spring is softened to 0.6 / interval, so the staircase of targets becomes a
/// near-constant-velocity glide (under 10% velocity ripple instead of a
/// visible step per repeat). When the repeats stop, the spring stiffens back
/// only as fast as it can without accelerating (omega <= 2|v|/|error|), so
/// releasing the key eases out with no lurch, in about 0.25-0.5 s.
@MainActor
final class SmoothScroller: NSObject {
    var isEnabled = true
    /// Seconds for a single step to settle (to within 1%).
    var settleDuration: Double = 0.16

    /// Finds the scroll view (it may be created or replaced later, as
    /// PDFView does with its internal one).
    private let findScrollView: () -> NSScrollView?
    private weak var cachedScrollView: NSScrollView?
    /// Bracket motion with live-scroll notifications, like a trackpad
    /// scroll. PDFView needs them to update its current page.
    private let postsLiveScroll: Bool

    private(set) var target: CGPoint?
    private var velocity = CGVector.zero
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    /// What we last wrote to the clip view; anything else means the user or
    /// PDFKit moved it, and we yield.
    private var lastWritten: CGRect = .zero
    /// The exact animated origin (the clip view may round what it stores).
    private var position: CGPoint = .zero
    private var isLive = false
    private var lastImpulse: CFTimeInterval = 0
    /// Smoothed interval between scrolls while a key is being held.
    private var repeatInterval: CFTimeInterval?
    /// Set when a held key is released: the soft omega to ease out from.
    private var releaseOmega: Double?
    private var stats = FrameStats()

    /// Scrolls PDFView's internal scroll view (found lazily, re-found if
    /// PDFKit replaces it) and posts live-scroll notifications for it.
    convenience init(host: BPPDFView) {
        self.init(postsLiveScroll: true) { [weak host] in host?.enclosedScrollView }
    }

    /// Scrolls a scroll view the caller owns.
    convenience init(scrollView: NSScrollView) {
        self.init(postsLiveScroll: false) { [weak scrollView] in scrollView }
    }

    private init(postsLiveScroll: Bool, findScrollView: @escaping () -> NSScrollView?) {
        self.postsLiveScroll = postsLiveScroll
        self.findScrollView = findScrollView
    }

    // MARK: Geometry

    var scrollView: NSScrollView? {
        if let cachedScrollView, cachedScrollView.superview != nil { return cachedScrollView }
        cachedScrollView = findScrollView()
        return cachedScrollView
    }

    var clipView: NSClipView? { scrollView?.contentView }

    /// The visible rect in document coordinates.
    var viewport: CGRect? { clipView?.bounds }

    /// Where the viewport is headed: the animation target, else the origin.
    var destination: CGPoint? { target ?? viewport?.origin }

    /// View points per document unit (the zoom or magnification).
    var scale: CGFloat {
        guard let clip = clipView, clip.bounds.width > 0 else { return 1 }
        return clip.frame.width / clip.bounds.width
    }

    /// Clamps an origin to the scrollable range (the clip view's own rules,
    /// so content insets and centring of narrow documents are respected).
    func clamp(_ origin: CGPoint) -> CGPoint {
        guard let clip = clipView else { return origin }
        return clip.constrainBoundsRect(CGRect(origin: origin, size: clip.bounds.size)).origin
    }

    // MARK: Scrolling

    /// Relative scroll (document units). Retargets a running animation.
    func scroll(by delta: CGVector) {
        guard let start = destination else { return }
        let goal = clamp(CGPoint(x: start.x + delta.dx, y: start.y + delta.dy))
        let now = CACurrentMediaTime()
        let interval = now - lastImpulse
        lastImpulse = now
        if target != nil, interval < 0.15 {
            repeatInterval = repeatInterval.map { 0.5 * $0 + 0.5 * interval } ?? interval
        } else {
            repeatInterval = nil
        }
        releaseOmega = nil
        animate(to: goal)
    }

    /// Absolute scroll. Animates when the distance is under three viewport
    /// heights, otherwise jumps.
    func jump(to origin: CGPoint) {
        guard let viewport else { return }
        let goal = clamp(origin)
        let from = destination ?? viewport.origin
        repeatInterval = nil
        releaseOmega = nil
        if hypot(goal.x - from.x, goal.y - from.y) < 3 * viewport.height {
            animate(to: goal)
        } else {
            set(goal)
        }
    }

    /// Moves instantly, cancelling any animation.
    func set(_ origin: CGPoint) {
        stop()
        beginLiveScroll()
        write(clamp(origin))
        endLiveScroll()
    }

    func stop() {
        target = nil
        velocity = .zero
        repeatInterval = nil
        releaseOmega = nil
        link?.invalidate()
        link = nil
        endLiveScroll()
    }

    private func animate(to goal: CGPoint) {
        guard isEnabled, let clip = clipView, clip.window != nil else {
            set(goal)
            return
        }
        target = goal
        guard link == nil else { return }
        lastWritten = clip.bounds
        position = clip.bounds.origin
        beginLiveScroll()
        lastTimestamp = CACurrentMediaTime()
        let link = clip.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        stats.begin(at: lastTimestamp)
    }

    private func write(_ origin: CGPoint) {
        guard let scrollView, let clip = clipView else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        lastWritten = clip.bounds
        position = origin
        // PDFView updates its current page (and page-changed notifications)
        // from live-scroll notifications, not from bounds changes.
        if postsLiveScroll {
            NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scrollView)
        }
    }

    /// Bracket programmatic motion like a trackpad scroll, so PDFView treats
    /// it the same way.
    private func beginLiveScroll() {
        guard postsLiveScroll, !isLive, let scrollView else { return }
        isLive = true
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
    }

    private func endLiveScroll() {
        guard isLive else { return }
        isLive = false
        guard let scrollView else { return }
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
    }

    /// True if the clip view is where we left it (allowing float noise).
    private func isUntouched(_ clip: NSClipView) -> Bool {
        let a = clip.bounds, b = lastWritten
        return abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01
            && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        stats.frame(at: now, nominal: link.duration)
        guard let clip = clipView, let goal = target, isUntouched(clip) else {
            // Someone else scrolled or zoomed (trackpad, scroller, pinch).
            finish()
            return
        }
        let dt = min(max(link.targetTimestamp - lastTimestamp, 0), 0.05)
        lastTimestamp = link.targetTimestamp
        let stiff = 6.64 / max(settleDuration, 0.01)
        if let held = repeatInterval, now - lastImpulse > 2 * held + 0.02 {
            repeatInterval = nil  // key released
            releaseOmega = min(stiff, 0.6 / held)
        }
        let omega: Double
        if let held = repeatInterval {
            omega = min(stiff, 0.6 / held)
        } else if let soft = releaseOmega {
            let error = hypot(position.x - goal.x, position.y - goal.y)
            let speed = hypot(velocity.dx, velocity.dy)
            omega = error > 0 ? min(stiff, max(soft, 2 * speed / error)) : stiff
        } else {
            omega = stiff
        }

        let (x, vx) = Self.spring(position.x - goal.x, velocity.dx, omega, dt)
        let (y, vy) = Self.spring(position.y - goal.y, velocity.dy, omega, dt)
        velocity = CGVector(dx: vx, dy: vy)

        // Settle when within a fraction of a screen point and nearly still.
        let s = scale
        if hypot(x, y) * s < 0.3, hypot(vx, vy) * s < 30 {
            write(goal)
            finish()
        } else {
            write(CGPoint(x: goal.x + x, y: goal.y + y))
        }
    }

    private func finish() {
        stop()
        stats.end()
    }

    /// Exact step of a critically damped spring: error `e`, velocity `v`.
    private static func spring(_ e: CGFloat, _ v: CGFloat, _ omega: Double,
                               _ dt: Double) -> (CGFloat, CGFloat) {
        let decay = exp(-omega * dt)
        let c = v + omega * e
        return ((e + c * dt) * decay, (v - omega * c * dt) * decay)
    }
}

/// With BP_SCROLL_STATS=1 (debug and release builds), logs frame pacing of each animation to stderr when
/// it settles. Measures main-thread callback times, so it exposes hitches
/// from synchronous work such as page rendering on the main thread.
private struct FrameStats {
    static let enabled = ProcessInfo.processInfo.environment["BP_SCROLL_STATS"] == "1"

    private var start: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var frames = 0
    private var worst: CFTimeInterval = 0
    private var late = 0
    private var nominal: CFTimeInterval = 0

    mutating func begin(at time: CFTimeInterval) {
        guard Self.enabled else { return }
        self = FrameStats()
        start = time
    }

    mutating func frame(at time: CFTimeInterval, nominal: CFTimeInterval) {
        guard Self.enabled else { return }
        if frames > 0 {
            let interval = time - last
            worst = max(worst, interval)
            if interval > nominal * 1.5 { late += 1 }
        } else {
            start = time
        }
        self.nominal = nominal
        last = time
        frames += 1
    }

    func end() {
        guard Self.enabled, frames > 1 else { return }
        let mean = (last - start) / Double(frames - 1)
        let line = String(format: "SCROLLSTATS frames=%d duration=%.0fms mean=%.2fms worst=%.2fms nominal=%.2fms late=%d\n",
                          frames, (last - start) * 1000, mean * 1000, worst * 1000, nominal * 1000, late)
        FileHandle.standardError.write(Data(line.utf8))
    }
}
