import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let filler = WindowFiller()
    private let fillHotKey = GlobalHotKey()
    private let fillAllHotKey = GlobalHotKey()
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var askedForAccessibility = false

    private lazy var newWindowWatcher = NewWindowWatcher { [weak self] pid, window in
        self?.fillNewWindow(window, of: pid)
    }

    private let fillNewItem = NSMenuItem(title: "Fill New Windows", action: #selector(toggleFillNew), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
    private let accessItem = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(grantAccess), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "fifi")
        statusItem.menu = buildMenu()

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

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Fill Window\t\(Shortcut.fillWindow.displayString)", action: #selector(fillFocusedWindowFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Fill All Windows\t\(Shortcut.fillAll.displayString)", action: #selector(fillAllFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        for item in [fillNewItem, loginItem, accessItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit fifi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        fillNewItem.state = settings.fillNewWindows ? .on : .off
        loginItem.state = settings.launchAtLogin ? .on : .off
        accessItem.isHidden = WindowFiller.isTrusted
    }

    @objc private func fillFocusedWindowFromMenu() { fillFocusedWindow() }
    @objc private func fillAllFromMenu() { fillAllWindows() }

    @objc private func toggleFillNew() {
        settings.fillNewWindows.toggle()
        updateNewWindowWatcher()
    }

    @objc private func toggleLaunchAtLogin() {
        settings.setLaunchAtLogin(!settings.launchAtLogin)
    }

    @objc private func grantAccess() {
        WindowFiller.requestTrust()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
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
