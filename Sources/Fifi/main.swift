import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    if CommandLine.arguments.contains("--plan-fill-all") { WindowFiller.debugPlanFillAll(); exit(0) }
    #endif

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
