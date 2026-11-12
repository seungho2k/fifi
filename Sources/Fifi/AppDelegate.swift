import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings.shared
    private let filler = WindowFiller()
    private let fillHotKey = GlobalHotKey()
    private let fillAllHotKey = GlobalHotKey()
    private var trustTimer: Timer?
    private var askedForAccessibility = false

    private lazy var newWindowWatcher = NewWindowWatcher { [weak self] pid, window in
        self?.fillNewWindow(window, of: pid)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        fillHotKey.onPress = { [weak self] in self?.fillFocusedWindow() }
        fillHotKey.register(.fillWindow)
        fillAllHotKey.onPress = { [weak self] in self?.fillAllWindows() }
        fillAllHotKey.register(.fillAll)

        if WindowFiller.isTrusted {
            updateNewWindowWatcher()
        } else {
            askForAccessibility()
            waitForTrust()
        }
    }

    // MARK: Accessibility

    private func askForAccessibility() {
        guard !askedForAccessibility else { return }
        askedForAccessibility = true
        WindowFiller.requestTrust()
    }

    /// Starts watching for new windows once the permission is granted.
    private func waitForTrust() {
        trustTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard WindowFiller.isTrusted else { return }
                timer.invalidate()
                self?.trustTimer = nil
                self?.updateNewWindowWatcher()
            }
        }
    }

    // MARK: Fill

    /// `fill-window`: the focused window of the app in front.
    private func fillFocusedWindow() {
        guard WindowFiller.isTrusted else { return askForAccessibility() }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        filler.fillFocusedWindow(of: pid)
    }

    /// `fill-all`: every eligible window on the current desktop.
    private func fillAllWindows() {
        guard WindowFiller.isTrusted else { return askForAccessibility() }
        filler.fillAllWindows(frontPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    private func updateNewWindowWatcher() {
        if settings.fillNewWindows { newWindowWatcher.start() } else { newWindowWatcher.stop() }
    }

    private func fillNewWindow(_ window: AXUIElement?, of pid: pid_t) {
        guard settings.fillNewWindows, pid != ProcessInfo.processInfo.processIdentifier else { return }
        filler.fillNewWindow(window, of: pid)
    }
}
