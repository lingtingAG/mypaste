import AppKit
import Carbon.HIToolbox
import Foundation

public struct Shortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let capture = Shortcut(keyCode: UInt32(kVK_F1))
    public static let pin = Shortcut(keyCode: UInt32(kVK_F3))
    public static let fullScreen = Shortcut(
        keyCode: UInt32(kVK_F1),
        modifiers: UInt32(optionKey)
    )

    public var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    public var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    public var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }
    public var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }

    public var displayString: String {
        var result = ""
        if hasControl { result += "⌃" }
        if hasOption { result += "⌥" }
        if hasShift { result += "⇧" }
        if hasCommand { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    public var nseventModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if hasCommand { flags.insert(.command) }
        if hasOption { flags.insert(.option) }
        if hasShift { flags.insert(.shift) }
        if hasControl { flags.insert(.control) }
        return flags
    }

    public static func from(event: NSEvent) -> Shortcut? {
        let keyCode = UInt32(event.keyCode)
        if invalidKeys.contains(keyCode) { return nil }
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return Shortcut(keyCode: keyCode, modifiers: modifiers)
    }

    private static let invalidKeys: Set<UInt32> = [
        UInt32(kVK_Command), UInt32(kVK_Shift), UInt32(kVK_CapsLock),
        UInt32(kVK_Option), UInt32(kVK_Control), UInt32(kVK_RightCommand),
        UInt32(kVK_RightShift), UInt32(kVK_RightOption), UInt32(kVK_RightControl),
        UInt32(kVK_Function),
    ]

    public static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "Home"
        case kVK_End: return "End"
        case kVK_PageUp: return "Page Up"
        case kVK_PageDown: return "Page Down"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        case kVK_F20: return "F20"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        default: return "Key \(keyCode)"
        }
    }
}

public extension Notification.Name {
    static let myPasteSettingsDidChange = Notification.Name("com.mypaste.settingsDidChange")
    static let myPasteHistoryDidChange = Notification.Name("com.mypaste.historyDidChange")
}
