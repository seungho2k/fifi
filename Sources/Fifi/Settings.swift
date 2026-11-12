import AppKit
import ServiceManagement

@MainActor
final class Settings {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Windows other apps open are filled like fill-window.
    var fillNewWindows: Bool {
        didSet { defaults.set(fillNewWindows, forKey: "fillNewWindows") }
    }

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    private init() {
        fillNewWindows = defaults.object(forKey: "fillNewWindows") as? Bool ?? true
        // Launch at login is on by default: turned on once, on the first run of the installed
        // app (afterwards the setting is whatever the user chose).
        if Bundle.main.bundleIdentifier == "com.seungho.fifi", !defaults.bool(forKey: "launchAtLoginDefaulted") {
            defaults.set(true, forKey: "launchAtLoginDefaulted")
            if !launchAtLogin { setLaunchAtLogin(true) }
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("fifi: launch at login change failed: \(error)")
        }
    }
}
