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

    static let space: UInt16 = 49

    /// `fill-window`: ⌥Space
    static let fillWindow = Shortcut(keyCode: space, modifiers: [.option])
    /// `fill-all`: ⌥⌘Space
    static let fillAll = Shortcut(keyCode: space, modifiers: [.option, .command])

}
