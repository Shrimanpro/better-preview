import Darwin
import Foundation
import os

/// `BP_LAUNCH_TIMING=1`: logs milestones of the launch to stderr, in ms since
/// the process was created (kernel start time, so dyld and static
/// initialisers count too):
///
///   LAUNCH main=12 finished-launching=60 window-shown=95 first-layout=110 first-page-drawn=140
///
/// `first-page-drawn` is when PDFKit finished drawing the first tile of any
/// page (on its render thread), i.e. when the first page content can reach
/// the screen. Costs one atomic check per page draw when disabled.
enum LaunchTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["BP_LAUNCH_TIMING"] == "1"

    private static let state = OSAllocatedUnfairLock(initialState: [String]())
    private static let done = OSAllocatedUnfairLock(initialState: false)

    /// Process creation time, from the kernel.
    private static let processStart: Date = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let tv = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
    }()

    /// Records a milestone once (later calls with the same name are ignored).
    /// Thread-safe. Writes the line when `first-page-drawn` arrives.
    static func mark(_ name: String) {
        guard isEnabled, !done.withLock({ $0 }) else { return }
        let ms = Int((Date().timeIntervalSince(processStart) * 1000).rounded())
        let line: String? = state.withLock { marks in
            guard !marks.contains(where: { $0.hasPrefix(name + "=") }) else { return nil }
            marks.append("\(name)=\(ms)")
            return name == "first-page-drawn" ? marks.joined(separator: " ") : nil
        }
        if let line {
            done.withLock { $0 = true }
            FileHandle.standardError.write(Data("LAUNCH \(line)\n".utf8))
        }
    }
}
