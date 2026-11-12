import AppKit
import ApplicationServices

/// Reports windows other apps open, on the main thread: an Accessibility observer per running
/// regular app (window created), and, for an app that just launched, a report once it's
/// observable (its first windows may open before that). Apps that don't announce new windows
/// (Adobe apps) are caught when a window fifi hasn't seen before becomes focused or main.
/// Needs the Accessibility permission.
@MainActor
final class NewWindowWatcher {
    /// `window` is nil for an app that just launched: all its windows are new.
    private let onNewWindow: (_ pid: pid_t, _ window: AXUIElement?) -> Void
    private var observers: [pid_t: AXObserver] = [:]
    /// Windows each app had or opened, so a focus change to one of them isn't taken as new.
    private var known: [pid_t: [AXUIElement]] = [:]
    private var tokens: [NSObjectProtocol] = []
    private(set) var isRunning = false

    init(onNewWindow: @escaping (_ pid: pid_t, _ window: AXUIElement?) -> Void) {
        self.onNewWindow = onNewWindow
    }

    func start() {
        guard !isRunning, WindowFiller.isTrusted else { return }
        isRunning = true
        for app in NSWorkspace.shared.runningApplications { observe(app, launched: false) }
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.observe(app, launched: true) }
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.forget(app.processIdentifier) }
        })
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        tokens = []
        for pid in Array(observers.keys) { forget(pid) }
    }

    private func observe(_ app: NSRunningApplication, launched: Bool, attempt: Int = 0) {
        let pid = app.processIdentifier
        guard isRunning, observers[pid] == nil, !app.isTerminated, app.activationPolicy == .regular,
              pid != ProcessInfo.processInfo.processIdentifier else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, windowCreatedCallback, &observer) == .success, let observer else { return }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, 0.3)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon) == .success else {
            // A launching app may not answer yet: try again for a few seconds.
            if attempt < 10 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.observe(app, launched: launched, attempt: attempt + 1)
                }
            }
            return
        }
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXMainWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
        // Windows open now are known: either old, or filled below as the launch's windows.
        known[pid] = Self.currentWindows(of: element)
        if launched { onNewWindow(pid, nil) }
    }

    private func forget(_ pid: pid_t) {
        known[pid] = nil
        guard let observer = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    /// A window was created, or became focused or main: reported if fifi hasn't seen it before.
    fileprivate func noticed(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard isRunning, AXUIElementGetPid(element, &pid) == .success, observers[pid] != nil else { return }
        var window = element
        if !Self.isWindow(element) {
            // Some apps send the app as the element: take its focused window.
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            window = value as! AXUIElement
        }
        var list = known[pid] ?? []
        guard !list.contains(where: { CFEqual($0, window) }) else { return }
        // Forget windows that have closed (their elements no longer answer).
        list.removeAll { !Self.isWindow($0) }
        list.append(window)
        known[pid] = list
        onNewWindow(pid, window)
    }

    private static func isWindow(_ element: AXUIElement) -> Bool {
        var role: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success
            && role as? String == kAXWindowRole
    }

    private static func currentWindows(of app: AXUIElement) -> [AXUIElement] {
        var list: [AXUIElement] = []
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success, let windows = value as? [AXUIElement] {
            list = windows
        }
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var v: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, attr as CFString, &v) == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
                let w = v as! AXUIElement
                if !list.contains(where: { CFEqual($0, w) }) { list.append(w) }
            }
        }
        return list
    }
}

private let windowCreatedCallback: AXObserverCallback = { _, element, _, refcon in
    guard let refcon else { return }
    let watcher = Unmanaged<NewWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    MainActor.assumeIsolated { watcher.noticed(element) }
}
