import AppKit
import ApplicationServices

/// Fills other apps' windows to their screen's usable area (minus small margins).
///
/// Uses the Accessibility API, so it needs the Accessibility permission. Only windows on the
/// current desktop are touched (not minimized, full-screen or modal ones). AX calls run on a
/// background queue with a short timeout, so a busy app can't stall fifi.
final class WindowFiller: @unchecked Sendable {
    /// Space between the screen's sides and a filled window.
    static let screenSideMargin: CGFloat = 16
    /// Space above and below a filled window (inside the menu bar and Dock).
    static let screenVerticalMargin: CGFloat = 8

    /// The frame a filled window gets on a screen whose usable area is `visible`.
    static func filledFrame(visible: CGRect) -> CGRect {
        visible.insetBy(dx: screenSideMargin, dy: screenVerticalMargin)
    }

    private let queue = DispatchQueue(label: "fifi.window-filler")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends the user to the Accessibility settings.
    static func requestTrust() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    // MARK: Geometry (AX coordinates: origin at the primary screen's top-left, y down)

    static func axRect(_ r: NSRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// A screen rectangle (AX coordinates) and its usable area.
    private struct ScreenArea { let frame: CGRect; let visible: CGRect }

    private static func currentScreens() -> [ScreenArea] {
        NSScreen.screens.map { ScreenArea(frame: axRect($0.frame), visible: axRect($0.usableFrame)) }
    }

    /// Indices of `depths` (0 = frontmost) ordered from the backmost to the frontmost.
    static func backToFront(_ depths: [Int]) -> [Int] {
        depths.indices.sorted { depths[$0] > depths[$1] }
    }

    /// Stacking depth (0 = frontmost) of the on-screen window of `pid` at `frame`, or nil.
    private static func depth(of pid: pid_t, frame: CGRect, in stack: [(pid: pid_t, bounds: CGRect)]) -> Int? {
        stack.firstIndex { $0.pid == pid && close($0.bounds, frame) }
    }

    // MARK: Fill

    /// `fill-window`: the focused window of `pid` fills the screen it's mostly on.
    func fillFocusedWindow(of pid: pid_t) {
        let screens = Self.currentScreens()
        let lineUp = Self.linesUp(pid)
        queue.async { [self] in
            guard let window = Self.focusedWindow(of: pid),
                  Self.isAdjustable(window, anySize: true), let current = Self.frame(of: window) else { return }
            if lineUp {
                lineUpAll(of: pid, with: window, current: current, screens: screens)
                return
            }
            fill(window, current: current, screens: screens)
        }
    }

    /// How long a new window gets to settle before it's filled (apps often place a window right
    /// after creating it).
    static let newWindowDelay: TimeInterval = 0.3

    /// Later looks at a new window that wasn't ready to fill yet (Adobe apps create a window
    /// small or off screen and show it at its size a moment later).
    static let newWindowRetries: [TimeInterval] = [0.7, 1.5]

    /// `fill-new-windows`: fills a window another app just opened (or, with `window` nil, the
    /// windows of an app that just launched) like `fill-window`, once it has settled. Only
    /// document windows shown on the current desktop (see `isAdjustable`): dialogs, palettes and
    /// popups are left alone.
    func fillNewWindow(_ window: AXUIElement?, of pid: pid_t, attempt: Int = 0) {
        let screens = Self.currentScreens()
        let lineUp = Self.linesUp(pid)
        let delay = attempt == 0 ? Self.newWindowDelay : Self.newWindowRetries[attempt - 1]
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            let stack = Self.onScreenWindows()
            for candidate in window.map({ [$0] }) ?? Self.windows(of: pid) {
                let subrole = Self.attribute(candidate, kAXSubroleAttribute) as? String
                guard subrole != kAXDialogSubrole, subrole != kAXSystemDialogSubrole,
                      Self.isAdjustable(candidate), let current = Self.frame(of: candidate),
                      Self.depth(of: pid, frame: current, in: stack) != nil else {
                    if let window, attempt < Self.newWindowRetries.count {
                        DispatchQueue.main.async { self.fillNewWindow(window, of: pid, attempt: attempt + 1) }
                    }
                    continue
                }
                if lineUp {
                    lineUpAll(of: pid, with: candidate, current: current, screens: screens)
                    return
                }
                fill(candidate, current: current, screens: screens)
            }
        }
    }

    /// `fill-all`: every eligible window on the current desktop (all apps, all screens) fills its
    /// screen, back to front so only the frontmost change shows.
    /// `frontPID`: the app you're working in; its focused window is always included, even when
    /// the window server doesn't list it as on screen (Adobe Premiere Pro, at times).
    func fillAllWindows(frontPID: pid_t?) {
        let screens = Self.currentScreens()
        let pids = Self.otherAppPIDs()
        let lineUpPIDs = Set(pids.filter { Self.linesUp($0) })
        queue.async { [self] in
            let stack = Self.onScreenWindows()
            var targets: [(window: AXUIElement, current: CGRect, depth: Int)] = []
            var groups: [pid_t: [(window: AXUIElement, current: CGRect)]] = [:]
            for pid in pids {
                let focused = pid == frontPID ? Self.focusedWindow(of: pid) : nil
                for window in Self.windows(of: pid) {
                    guard let current = Self.frame(of: window) else { continue }
                    let isFrontWindow = focused.map { CFEqual($0, window) } ?? false
                    // On this desktop (or the window you're working in), and resizable.
                    guard let depth = Self.depth(of: pid, frame: current, in: stack) ?? (isFrontWindow ? 0 : nil),
                          Self.isAdjustable(window, anySize: isFrontWindow) else { continue }
                    if lineUpPIDs.contains(pid) { groups[pid, default: []].append((window, current)); continue }
                    targets.append((window, current, depth))
                }
            }
            for k in Self.backToFront(targets.map(\.depth)) {
                fill(targets[k].window, current: targets[k].current, screens: screens)
            }
            for group in groups.values { lineUpWindows(group, screens: screens) }
        }
    }

    #if DEBUG
    /// Dry run of `fillAllWindows`: prints each candidate window and whether it would be filled.
    static func debugPlanFillAll() {
        let stack = onScreenWindows()
        for pid in otherAppPIDs() {
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            for window in windows(of: pid) {
                let f = frame(of: window)
                let depth = f.flatMap { depth(of: pid, frame: $0, in: stack) }
                let ok = isAdjustable(window)
                print("\(name): frame=\(f.map { "\($0)" } ?? "nil") onThisDesktop=\(depth != nil) adjustable=\(ok) subrole=\(attribute(window, kAXSubroleAttribute) as? String ?? "nil") -> \(f != nil && depth != nil && ok ? "FILL" : "skip")")
            }
        }
    }
    #endif

    /// Fills one window on the screen it mostly lies on (queue only).
    private func fill(_ window: AXUIElement, current: CGRect, screens: [ScreenArea]) {
        guard let screen = screens.max(by: { Self.overlap($0.frame, current) < Self.overlap($1.frame, current) })
        else { return }
        Self.setFrame(Self.filledFrame(visible: screen.visible), of: window, from: current)
    }

    // MARK: Lined-up apps

    /// Apps whose windows aren't widened by fill: each one fills the height at its smallest
    /// width, and the app's windows line up left to right, its main window first. KakaoTalk's
    /// chat windows are narrow by design, and a full-width one is mostly empty.
    static let lineUpBundleIDs: Set<String> = ["com.kakao.KakaoTalkMac"]
    /// The main window of a lined-up app (its `AXIdentifier`): KakaoTalk's friends/chats/more window.
    static let lineUpMainWindowIDs: Set<String> = ["Main Window"]
    /// Space between lined-up windows: none, they sit flush.
    static let lineUpGap: CGFloat = 0

    static func linesUp(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(lineUpBundleIDs.contains) ?? false
    }

    /// Where the next lined-up window goes: at `x`, or as far right as still fits in `area`
    /// (never left of it), so windows past the right end pile up at the end.
    static func lineUpX(width: CGFloat, at x: CGFloat, in area: CGRect) -> CGFloat {
        max(area.minX, min(x, area.maxX - width))
    }

    /// The order to line windows up in: main windows first, then left to right as they are.
    static func lineUpOrder(isMain: [Bool], minX: [CGFloat]) -> [Int] {
        isMain.indices.sorted { a, b in
            isMain[a] != isMain[b] ? isMain[a] : minX[a] < minX[b]
        }
    }

    /// Lines up `window` with the app's other windows on this desktop (queue only).
    private func lineUpAll(of pid: pid_t, with window: AXUIElement, current: CGRect, screens: [ScreenArea]) {
        let stack = Self.onScreenWindows()
        var group = [(window: window, current: current)]
        for other in Self.windows(of: pid) where !CFEqual(other, window) {
            guard let f = Self.frame(of: other), Self.depth(of: pid, frame: f, in: stack) != nil,
                  Self.isAdjustable(other) else { continue }
            group.append((other, f))
        }
        lineUpWindows(group, screens: screens)
    }

    /// Lines up one app's windows on each screen (queue only): each fills the fill area's height
    /// at its smallest width (asked for 1pt, the app clamps it), left to right from the area's
    /// left edge.
    private func lineUpWindows(_ group: [(window: AXUIElement, current: CGRect)], screens: [ScreenArea]) {
        var byScreen: [Int: [(window: AXUIElement, current: CGRect)]] = [:]
        for item in group {
            guard let i = screens.indices.max(by: { Self.overlap(screens[$0].frame, item.current) < Self.overlap(screens[$1].frame, item.current) })
            else { continue }
            byScreen[i, default: []].append(item)
        }
        for (i, items) in byScreen {
            let area = Self.filledFrame(visible: screens[i].visible)
            let isMain = items.map { Self.lineUpMainWindowIDs.contains(Self.attribute($0.window, kAXIdentifierAttribute) as? String ?? "") }
            var x = area.minX
            for k in Self.lineUpOrder(isMain: isMain, minX: items.map(\.current.minX)) {
                let (window, current) = items[k]
                Self.setFrame(CGRect(x: x, y: area.minY, width: 1, height: area.height), of: window, from: current)
                let width = Self.frame(of: window)?.width ?? current.width
                let placed = CGRect(x: Self.lineUpX(width: width, at: x, in: area), y: area.minY, width: width, height: area.height)
                if placed.minX != x { Self.setFrame(placed, of: window) }
                x = placed.maxX + Self.lineUpGap
            }
        }
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }

    // MARK: AX helpers

    /// Regular, visible apps other than fifi.
    private static func otherAppPIDs() -> [pid_t] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPID && !$0.isHidden }
            .map(\.processIdentifier)
    }

    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }

    /// On-screen (current desktop), normal-layer windows, frontmost first, with their bounds in
    /// AX coordinates.
    private static func onScreenWindows() -> [(pid: pid_t, bounds: CGRect)] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return (pid, rect)
        }
    }

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let focused = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        return (focused as! AXUIElement)
    }

    /// The app's windows, plus its focused window if the list leaves it out (Adobe Premiere Pro
    /// lists no windows at all; its main window is only reachable as the focused window).
    private static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        var list = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        if let focused = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let window = focused as! AXUIElement
            if !list.contains(where: { CFEqual($0, window) }) { list.append(window) }
        }
        return list
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// A window fifi may resize: not minimized, full screen or modal, size and position
    /// settable, and either a standard window or — for apps that don't label their main window
    /// as one, like Adobe Premiere Pro (a "floating window") — at least `documentSize`, so tool
    /// palettes and popups stay out. `anySize`: the user picked this window (fill-window), so
    /// size doesn't matter.
    private static func isAdjustable(_ window: AXUIElement, anySize: Bool = false) -> Bool {
        guard attribute(window, kAXMinimizedAttribute) as? Bool != true,
              attribute(window, "AXFullScreen") as? Bool != true,
              attribute(window, kAXModalAttribute) as? Bool != true,
              isSettable(window, kAXSizeAttribute), isSettable(window, kAXPositionAttribute) else { return false }
        if anySize || attribute(window, kAXSubroleAttribute) as? String == kAXStandardWindowSubrole { return true }
        guard let size = frame(of: window)?.size else { return false }
        return looksLikeDocument(size)
    }

    /// Non-standard windows at least this big are treated as document windows.
    static let documentSize = CGSize(width: 400, height: 300)
    static func looksLikeDocument(_ size: CGSize) -> Bool {
        size.width >= documentSize.width && size.height >= documentSize.height
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let p = attribute(window, kAXPositionAttribute), let s = attribute(window, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &origin), AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Moves and resizes `window` to `r`. Size, then position, then size again (a window can't
    /// grow past a screen edge it hasn't moved away from yet); a window that stays where it is
    /// gets just one resize. Then checks: on stacked displays, a window that crosses into the
    /// other display while it changes can be pushed onto it by macOS, so if it didn't land on
    /// `r`, it's moved there again (position first this time). Apps with the "enhanced user
    /// interface" accessibility flag on (some browsers, Electron apps) animate and fight the
    /// change, so it's off while the window changes.
    private static func setFrame(_ r: CGRect, of window: AXUIElement, from current: CGRect? = nil) {
        var origin = r.origin, size = r.size
        guard let p = AXValueCreate(.cgPoint, &origin), let s = AXValueCreate(.cgSize, &size) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let app = AXUIElementCreateApplication(pid)
        let enhanced = attribute(app, "AXEnhancedUserInterface") as? Bool == true
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }

        func setPosition() { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) }
        func setSize() { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s) }
        setSize()
        if let current, abs(current.minX - r.minX) < 1, abs(current.minY - r.minY) < 1 {
            // Stays in place: one resize (unless macOS moved it meanwhile).
        } else {
            setPosition()
            setSize()
        }
        if let landed = frame(of: window), !close(landed.origin, r.origin) {
            setPosition()
            setSize()
            setPosition()
        }
    }

    private static func close(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 2 && abs(a.y - b.y) < 2
    }
}
