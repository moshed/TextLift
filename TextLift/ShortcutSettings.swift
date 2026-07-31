import AppKit
import Carbon.HIToolbox

/// A global keyboard shortcut: a virtual key code plus modifier flags.
/// `NSEvent.keyCode` and Carbon's `RegisterEventHotKey` use the same virtual
/// key codes, so the same value serves both display and registration.
struct Shortcut: Equatable {
    var keyCode: UInt32
    var modifierFlags: NSEvent.ModifierFlags

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_T),
                                    modifierFlags: [.control, .option])

    /// Modifier mask in the Carbon form `RegisterEventHotKey` expects.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifierFlags.contains(.command) { m |= UInt32(cmdKey) }
        if modifierFlags.contains(.option)  { m |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { m |= UInt32(controlKey) }
        if modifierFlags.contains(.shift)   { m |= UInt32(shiftKey) }
        return m
    }

    /// Human-readable form, e.g. "⌥⌘V".
    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option)  { s += "⌥" }
        if modifierFlags.contains(.shift)   { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        s += Shortcut.keyName(for: keyCode)
        return s
    }

    static func keyName(for keyCode: UInt32) -> String {
        if let special = specialKeys[Int(keyCode)] { return special }
        if let ansi = ansiKeys[Int(keyCode)] { return ansi }
        return "Key\(keyCode)"
    }

    private static let specialKeys: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫",
        kVK_Escape: "⎋", kVK_ForwardDelete: "⌦", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "?⃝",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
    ]
}

/// Persists the chosen shortcut in `UserDefaults`.
enum ShortcutStore {
    private static let codeKey = "hotKeyCode"
    private static let modsKey = "hotKeyModifierFlags"

    static func load() -> Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: codeKey) != nil else { return .default }
        let code = UInt32(d.integer(forKey: codeKey))
        let mods = NSEvent.ModifierFlags(rawValue: UInt(d.integer(forKey: modsKey)))
        return Shortcut(keyCode: code, modifierFlags: mods)
    }

    static func save(_ s: Shortcut) {
        let d = UserDefaults.standard
        d.set(Int(s.keyCode), forKey: codeKey)
        d.set(Int(s.modifierFlags.rawValue), forKey: modsKey)
    }
}
