import AppKit
import ApplicationServices
import Foundation
import os

final class CompositeInjector: TextInjector, ContextAwareInjector {
    private let primary: TextInjector
    private let fallback: TextInjector
    private let log = Logger(subsystem: "com.tylersimmons.speek", category: "injection")

    init(primary: TextInjector = AXInjector(), fallback: TextInjector = TypingInjector()) {
        self.primary = primary
        self.fallback = fallback
    }

    func insert(_ text: String) async throws -> InjectionResult {
        try await insertCore(text, adjustToContext: true)
    }

    private func insertCore(_ text: String, adjustToContext: Bool) async throws -> InjectionResult {
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

        var adjusted = text
        if adjustToContext {
            let context = Self.fieldContextBeforeCursor()
            // Case first (needs the text's first letter), then space.
            adjusted = Self.smartCased(text, afterMeaningful: context.lastMeaningful)
            adjusted = Self.smartSpaced(adjusted, afterPrevious: context.immediate)
        }

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

    // MARK: - Context-aware insertion (seam repair)

    /// Applies a context-merged pipeline output.
    /// - Fragment unchanged in the merged text → insert only the continuation,
    ///   verbatim (the model already handled spacing and casing at the seam).
    /// - Fragment corrected → replace the fragment span in place, bounded to
    ///   the current sentence.
    /// - Anything unsafe (field changed, AX refused, verification failed) →
    ///   fall back to plain insertion of the regex-formatted dictation.
    func insert(_ output: FormattingPipeline.Output, snapshot: FieldSnapshot?) async throws -> InjectionResult {
        guard output.mergedFragment, let snapshot, !snapshot.fragment.isEmpty else {
            return try await insert(output.text)
        }
        if let suffix = Self.suffixAfterFragment(fragment: snapshot.fragment, merged: output.text) {
            // Model kept the fragment verbatim — just append the continuation.
            let trimmed = suffix
            guard !trimmed.isEmpty else { return .inserted } // nothing new to add
            log.debug("seam: fragment unchanged — inserting continuation only")
            return try await insertCore(trimmed, adjustToContext: false)
        }
        if Self.replaceFragment(snapshot: snapshot, with: output.text) {
            log.debug("seam: fragment corrected — replaced in place")
            return .inserted
        }
        log.debug("seam: repair unavailable — plain insertion fallback")
        return try await insert(output.plainFallback)
    }

    /// If `merged` starts with the fragment (exactly, or modulo trailing
    /// whitespace normalization), returns the continuation after it.
    static func suffixAfterFragment(fragment: String, merged: String) -> String? {
        if merged.hasPrefix(fragment) {
            return String(merged.dropFirst(fragment.count))
        }
        let trimmed = String(fragment.reversed().drop(while: { $0.isWhitespace }).reversed())
        if !trimmed.isEmpty, merged.hasPrefix(trimmed) {
            return String(merged.dropFirst(trimmed.count))
        }
        return nil
    }

    /// Replaces the snapshot's fragment span with the merged sentence, in
    /// place, via AX selection. Every step is guarded; any failure restores
    /// the caret and returns false so the caller can fall back safely.
    private static func replaceFragment(snapshot: FieldSnapshot, with merged: String) -> Bool {
        // Apps that lie about AX writes (Messages) can't be trusted with a
        // destructive span replacement — verification reads their mirror
        // store, not the visible composer.
        if let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           axBlacklistedBundleIDs.contains(bundle) { return false }

        // The field must be exactly as we snapshotted it: same prefix, caret
        // still sitting at the end of it, no selection.
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(snapshot.element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String, value.hasPrefix(snapshot.prefix) else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rr = rangeRef else { return false }
        var selection = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rr as! AXValue, .cfRange, &selection),
              selection.length == 0,
              selection.location == snapshot.prefixUTF16Length else { return false }

        let fragmentLength = snapshot.fragment.utf16.count
        let location = snapshot.prefixUTF16Length - fragmentLength
        guard location >= 0, fragmentLength > 0 else { return false }

        // Select the fragment span.
        var span = CFRange(location: location, length: fragmentLength)
        guard let axSpan = AXValueCreate(.cfRange, &span),
              AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, axSpan) == .success else {
            return false
        }

        // From here on, a failure leaves the fragment selected — restore the
        // caret so a fallback insertion can't overwrite the user's text.
        func restoreCaretAndFail() -> Bool {
            var caret = CFRange(location: snapshot.prefixUTF16Length, length: 0)
            if let axCaret = AXValueCreate(.cfRange, &caret) {
                AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, axCaret)
            }
            return false
        }

        guard AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextAttribute as CFString, merged as CFTypeRef) == .success else {
            return restoreCaretAndFail()
        }

        // Verify the write actually landed where we aimed it.
        var afterRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(snapshot.element, kAXValueAttribute as CFString, &afterRef) == .success,
              let after = afterRef as? String else { return restoreCaretAndFail() }
        let prefixUnits = Array(snapshot.prefix.utf16)
        let keptPrefix = String(decoding: prefixUnits[0..<location], as: UTF16.self)
        guard after.hasPrefix(keptPrefix + merged) else { return restoreCaretAndFail() }

        // Park the caret at the end of the merged sentence.
        var caret = CFRange(location: location + merged.utf16.count, length: 0)
        if let axCaret = AXValueCreate(.cfRange, &caret) {
            AXUIElementSetAttributeValue(snapshot.element, kAXSelectedTextRangeAttribute as CFString, axCaret)
        }
        return true
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

    struct FieldContext {
        /// Character immediately before the cursor (drives smart spacing).
        var immediate: Character?
        /// Last "meaningful" character before the cursor — skipping back over
        /// whitespace, newlines, and closing quotes/brackets (drives smart
        /// casing: is the cursor mid-sentence or at a sentence start?).
        var lastMeaningful: Character?
    }

    /// Best-effort read of the text before the cursor in the focused element.
    /// Returns empty context if the field doesn't expose its value via AX
    /// (common in Electron/web apps) — smartSpaced and smartCased both no-op
    /// on nil and leave the pipeline's default formatting untouched.
    private static func fieldContextBeforeCursor() -> FieldContext {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return FieldContext() }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef)
        AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef)

        guard let value = valueRef as? String, !value.isEmpty else { return FieldContext() }

        var range = CFRange(location: 0, length: 0)
        if let rangeRef = rangeRef {
            AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        }
        let cursor = max(0, min(value.count, range.location))
        guard cursor > 0 else { return FieldContext() }
        let prefix = String(value.prefix(cursor))
        return contextFrom(prefix: prefix)
    }

    /// Derives the field context from the text before the cursor. Split out
    /// from the AX read so it's unit-testable.
    static func contextFrom(prefix: String) -> FieldContext {
        guard let immediate = prefix.last else { return FieldContext() }
        // Scan back past whitespace and closing punctuation to the character
        // that actually determines sentence position: `he said "stop."` — the
        // quote is skipped so the period drives capitalization; `(like this)`
        // — the paren is skipped so the 's' marks a mid-sentence continuation.
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}"]
        let meaningful = prefix.reversed().first { !$0.isWhitespace && !$0.isNewline && !closers.contains($0) }
        return FieldContext(immediate: immediate, lastMeaningful: meaningful)
    }

    /// Lowercases the insert's first letter when the cursor sits mid-sentence
    /// (the effective previous character isn't a sentence ender). The regex
    /// and LLM stages always capitalize their output as a standalone sentence;
    /// this reconciles that with the surrounding text so continuations read
    /// seamlessly ("and then we went to" + "the store" — not "The store").
    ///
    /// Guards: "I" and its contractions stay capitalized, as do words with
    /// interior capitals (acronyms like PDF, names like McDonald). Plain
    /// proper nouns can't be distinguished cheaply and will be lowercased —
    /// mid-sentence continuations overwhelmingly start with common words, so
    /// this trades a rare miss for the common case.
    static func smartCased(_ text: String, afterMeaningful previous: Character?) -> String {
        guard let previous else { return text }               // empty/unreadable field
        if ".!?…".contains(previous) || previous.isNewline { return text } // sentence start
        guard let first = text.first, first.isUppercase else { return text }

        let firstWord = text.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        // "I", "I'm", "I'll", "I've", "I'd" stay capitalized.
        if firstWord == "I" || firstWord.hasPrefix("I'") || firstWord.hasPrefix("I\u{2019}") { return text }
        // Interior capitals → acronym or proper name, leave alone.
        if firstWord.dropFirst().contains(where: { $0.isUppercase }) { return text }

        return first.lowercased() + text.dropFirst()
    }
}
