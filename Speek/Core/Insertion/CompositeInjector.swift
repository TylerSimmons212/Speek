import AppKit
import ApplicationServices
import Foundation
import os

final class CompositeInjector: TextInjector {
    private let primary: TextInjector
    private let fallback: TextInjector
    private let log = Logger(subsystem: "com.tylersimmons.speek", category: "injection")

    init(primary: TextInjector = AXInjector(), fallback: TextInjector = TypingInjector()) {
        self.primary = primary
        self.fallback = fallback
    }

    func insert(_ text: String) async throws -> InjectionResult {
        // Wake up the front app's AX tree if it's an Electron/Chromium host —
        // their accessibility trees are dormant by default and refuse to
        // expose text-input roles until we set these attributes.
        Self.coaxFrontmostAppAX()

        switch Self.focusedElementVerdict() {
        case .editable:
            break // continue to the AX → keystroke insertion flow below

        case .opaqueApp:
            // The focused app refuses to answer accessibility queries at all
            // (dormant/none Electron tree, some cross-platform toolkits). We
            // can't know what's focused — but the user pressed the hotkey
            // with a caret somewhere, and synthesized keystrokes don't need
            // the AX tree. Type directly rather than punting to the clipboard.
            log.debug("focused app is AX-opaque — typing keystrokes directly")
            return try await fallback.insert(text)

        case .notEditable:
            // AX answered and the focus is genuinely not a text input — a
            // button, a Finder window, a read-only view. Typing here would
            // spray keystrokes into shortcut handlers; copy instead.
            log.debug("no text-editable focused; copying to clipboard only")
            let pb = NSPasteboard.general
            pb.clearContents()
            guard pb.setString(text, forType: .string) else {
                throw InjectionError.clipboardFailed
            }
            return .copied
        }

        let previousChar = Self.previousCharBeforeCursor()
        let adjusted = Self.smartSpaced(text, afterPrevious: previousChar)

        let useAX = await MainActor.run { SettingsStore.shared.axInsertionEnabled }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let axBlocked = frontmostBundleID.map(Self.axBlacklistedBundleIDs.contains) ?? false
        if useAX && !axBlocked {
            do {
                let result = try await primary.insert(adjusted)
                log.debug("AX injection succeeded")
                return result
            } catch {
                log.debug("AX injection failed (\(String(describing: error))) — falling back to synthesized keystrokes")
            }
        } else if axBlocked {
            log.debug("AX skipped for known-bad bundle \(frontmostBundleID ?? "?") — using synthesized keystrokes")
        }
        return try await fallback.insert(adjusted)
    }

    /// Bundle identifiers where AX reports a "successful" write but the visible
    /// text view doesn't update. These apps maintain a separate text store
    /// from their kAXValue mirror, so verification passes incorrectly. For
    /// these, skip AX entirely and go straight to synthesized keystrokes.
    private static let axBlacklistedBundleIDs: Set<String> = [
        "com.apple.MobileSMS",          // Messages
        "com.apple.iChat"               // Older Messages bundle ID
    ]

    /// Prepends a space to `text` when the character before the cursor is a
    /// letter, digit, or sentence-ending punctuation. Skipped when the field
    /// is empty, the cursor sits after whitespace, or after an opener like
    /// `(`, `[`, `{`, `"`, `'`.
    static func smartSpaced(_ text: String, afterPrevious previous: Character?) -> String {
        guard let previous = previous else { return text }
        if previous.isWhitespace { return text }
        if "([{\"'".contains(previous) { return text }
        return " " + text
    }

    /// What the accessibility system tells us about the current focus target.
    enum FocusVerdict {
        /// AX answered: focus is a text input — safe to insert.
        case editable
        /// AX answered: focus is not a text input (button, Finder, read-only).
        case notEditable
        /// AX refused to answer (Electron/Chromium with a dormant tree, some
        /// cross-platform toolkits). Focus state is unknowable via AX.
        case opaqueApp
    }

    /// Classifies the focused element. Editability signals, in priority order:
    ///   1. The role is one of the canonical text roles (TextField, TextArea,
    ///      ComboBox).
    ///   2. The subrole is SearchField or SecureTextField (subroles of
    ///      TextField — some apps only report the subrole).
    ///   3. `kAXSelectedTextRangeAttribute` is *settable* on the element
    ///      (gold-standard test from Apple's AX docs — true editable signal).
    /// Explicitly excludes `AXStaticText`, which is read-only.
    ///
    /// The error code of the focus query matters as much as the answer:
    /// `.noValue` means "nothing is focused" (a real answer → notEditable),
    /// while `.cannotComplete`/`.apiDisabled`/`.notImplemented` mean the app
    /// never responded — verified live against Electron apps whose trees stay
    /// dormant even after the AXManualAccessibility coax (→ opaqueApp).
    private static func focusedElementVerdict() -> FocusVerdict {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        switch err {
        case .success:
            break
        case .noValue, .attributeUnsupported:
            return .notEditable
        default:
            return .opaqueApp
        }
        guard let element = focused else { return .notEditable }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        // Read role + subrole up front.
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        // Hard exclude: read-only static text is never a target.
        if role == (kAXStaticTextRole as String) { return .notEditable }

        let textRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        if let role, textRoles.contains(role) { return .editable }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXSubroleAttribute as CFString, &subroleRef)
        if let subrole = subroleRef as? String {
            let textSubroles: Set<String> = [
                kAXSearchFieldSubrole as String,
                kAXSecureTextFieldSubrole as String
            ]
            if textSubroles.contains(subrole) { return .editable }
        }

        // Gold-standard editable test: is `kAXSelectedTextRangeAttribute`
        // settable on this element? This is a stronger signal than "attribute
        // exists" — a label may expose the attribute read-only but reject
        // writes; a real editable field accepts them.
        var settable: DarwinBoolean = false
        let settableErr = AXUIElementIsAttributeSettable(
            axElement,
            kAXSelectedTextRangeAttribute as CFString,
            &settable
        )
        if settableErr == .success && settable.boolValue { return .editable }

        return .notEditable
    }

    /// Electron and Chromium-based apps keep their AX trees dormant by
    /// default — children come back empty and text roles never appear. Setting
    /// `AXManualAccessibility` and `AXEnhancedUserInterface` on the app
    /// element wakes the tree so subsequent focused-element queries actually
    /// see the text input. Cheap to call every time; native Cocoa apps just
    /// ignore the unknown attribute write.
    private static func coaxFrontmostAppAX() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
    }

    /// Best-effort read of the character immediately before the cursor in the
    /// focused element. Used to decide whether to prepend a space. Returns nil
    /// if the field doesn't expose its value via AX (common in Electron/web
    /// apps) — in that case `smartSpaced` will no-op and let the host app deal
    /// with spacing.
    private static func previousCharBeforeCursor() -> Character? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef)
        AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)

        guard let value = valueRef as? String, !value.isEmpty else { return nil }

        var range = CFRange(location: 0, length: 0)
        if let rangeRef = rangeRef {
            AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        }
        let cursor = max(0, min(value.count, range.location))
        guard cursor > 0 else { return nil }
        let prevIndex = value.index(value.startIndex, offsetBy: cursor - 1)
        return value[prevIndex]
    }
}
