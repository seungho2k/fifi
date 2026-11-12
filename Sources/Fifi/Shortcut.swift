import AppKit

/// A key combination matched by physical key (keyCode), so it works regardless of input source (e.g. Korean).
struct Shortcut: Equatable, Hashable {
    var keyCode: UInt16
    var modifiers: UInt

    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    static let returnKey: UInt16 = 36

    /// `fill-window`: ⌃⌥↩
    static let fillWindow = Shortcut(keyCode: returnKey, modifiers: [.control, .option])
    /// `fill-all`: ⌃⌥⇧↩
    static let fillAll = Shortcut(keyCode: returnKey, modifiers: [.control, .option, .shift])

    var displayString: String {
        let f = modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + (keyCode == Self.returnKey ? "↩" : "#\(keyCode)")
    }
}
