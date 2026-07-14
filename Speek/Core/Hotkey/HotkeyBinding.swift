import CoreGraphics
import Foundation

/// The user's dictation trigger. Two safe families:
/// - a modifier key (Fn/Globe, either Command, Option, Control, or Shift —
///   side-specific via the hardware key code), or
/// - a function key F13–F20 (they emit no characters, so an unconsumed
///   listen-only tap can use them without side effects).
/// Regular character keys are deliberately unsupported: our event tap is
/// listen-only and cannot swallow keystrokes, so binding "A" would type
/// a stream of A's into the focused app while dictating.
enum HotkeyBinding: Codable, Equatable, Hashable {
    case modifier(flagRawValue: UInt64, keyCode: UInt16)
    case functionKey(keyCode: UInt16)

    // MARK: - Well-known keys

    static let fn = HotkeyBinding.modifier(flagRawValue: CGEventFlags.maskSecondaryFn.rawValue, keyCode: 63)
    static let rightCommand = HotkeyBinding.modifier(flagRawValue: CGEventFlags.maskCommand.rawValue, keyCode: 54)
    static let rightOption = HotkeyBinding.modifier(flagRawValue: CGEventFlags.maskAlternate.rawValue, keyCode: 61)

    /// F13–F20 hardware key codes.
    static let functionKeyCodes: Set<UInt16> = [105, 107, 113, 106, 64, 79, 80, 90]

    /// Maps a modifier key's hardware code to its CGEventFlags family bit.
    /// Returns nil for non-modifier key codes.
    static func modifierFlag(forKeyCode keyCode: UInt16) -> CGEventFlags? {
        switch keyCode {
        case 63: return .maskSecondaryFn          // Fn / Globe
        case 54, 55: return .maskCommand          // R⌘, L⌘
        case 58, 61: return .maskAlternate        // L⌥, R⌥
        case 59, 62: return .maskControl          // L⌃, R⌃
        case 56, 60: return .maskShift            // L⇧, R⇧
        default: return nil
        }
    }

    var flag: CGEventFlags? {
        if case .modifier(let raw, _) = self { return CGEventFlags(rawValue: raw) }
        return nil
    }

    var keyCode: UInt16 {
        switch self {
        case .modifier(_, let code): return code
        case .functionKey(let code): return code
        }
    }

    // MARK: - Display

    var displayName: String {
        switch self {
        case .modifier(_, let code):
            switch code {
            case 63: return "Fn (Globe)"
            case 54: return "Right ⌘"
            case 55: return "Left ⌘"
            case 58: return "Left ⌥"
            case 61: return "Right ⌥"
            case 59: return "Left ⌃"
            case 62: return "Right ⌃"
            case 56: return "Left ⇧"
            case 60: return "Right ⇧"
            default: return "Modifier (\(code))"
            }
        case .functionKey(let code):
            switch code {
            case 105: return "F13"
            case 107: return "F14"
            case 113: return "F15"
            case 106: return "F16"
            case 64: return "F17"
            case 79: return "F18"
            case 80: return "F19"
            case 90: return "F20"
            default: return "F-key (\(code))"
            }
        }
    }

    /// Short form for the onboarding keycap (e.g. "Fn", "R⌘", "F13").
    var keycapLabel: String {
        switch self {
        case .modifier(_, let code):
            switch code {
            case 63: return "Fn"
            case 54: return "R⌘"
            case 55: return "L⌘"
            case 58: return "L⌥"
            case 61: return "R⌥"
            case 59: return "L⌃"
            case 62: return "R⌃"
            case 56: return "L⇧"
            case 60: return "R⇧"
            default: return "Mod"
            }
        case .functionKey:
            return displayName
        }
    }

    // MARK: - Persistence

    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func from(jsonString: String) -> HotkeyBinding? {
        guard let data = jsonString.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(HotkeyBinding.self, from: data)
    }

    /// Migrates the legacy three-option setting ("fn" / "rightOption" /
    /// "rightCommand") persisted by earlier versions.
    static func fromLegacyChoice(_ raw: String) -> HotkeyBinding? {
        switch raw {
        case "fn": return .fn
        case "rightOption": return .rightOption
        case "rightCommand": return .rightCommand
        default: return nil
        }
    }
}
