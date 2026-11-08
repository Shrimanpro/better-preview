import AppKit

LaunchTiming.mark("main")
MainActor.assumeIsolated {
    PDFSelfTest.runIfRequested()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) { app.run() }
}
