import AppKit

extension NSScreen {
    /// The area for windows: `visibleFrame`, except that with an auto-hiding Dock its side is
    /// always free. macOS shrinks `visibleFrame` while the hidden Dock is shown under the mouse,
    /// so reading it at that moment would leave a Dock-sized gap (Window ▸ Fill has the same bug).
    var usableFrame: NSRect {
        Self.usable(frame: frame, visible: visibleFrame, dockAutohides: DockSettings.autohides, dockSide: DockSettings.side)
    }

    static func usable(frame: NSRect, visible: NSRect, dockAutohides: Bool, dockSide: DockSettings.Side) -> NSRect {
        guard dockAutohides else { return visible }
        var v = visible
        switch dockSide {
        case .bottom:
            v.size.height = v.maxY - frame.minY
            v.origin.y = frame.minY
        case .left:
            v.size.width = v.maxX - frame.minX
            v.origin.x = frame.minX
        case .right:
            v.size.width = frame.maxX - v.minX
        }
        return v
    }
}

/// The Dock's settings (read fresh each time: they can change while fifi runs).
enum DockSettings {
    enum Side { case bottom, left, right }

    static var autohides: Bool {
        value("autohide") as? Bool ?? false
    }

    static var side: Side {
        switch value("orientation") as? String {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }

    private static func value(_ key: String) -> Any? {
        let app = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(app)
        return CFPreferencesCopyAppValue(key as CFString, app)
    }
}
