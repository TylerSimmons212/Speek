import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import os

final class CompositeInjector: TextInjector {
    private let primary: TextInjector
    private let fallback: TextInjector
    private let paste: TextInjector = PasteInjector()
    private let log = Logger(subsystem: "com.tylersimmons.speek", category: "injection")

    init(primary: TextInjector = AXInjector(), fallback: TextInjector = TypingInjector()) {
        self.primary = primary
        self.fallback = fallback
    }

    func insert(_ text: String) async throws -> InjectionResult {
        try await insertCore(text, adjustToContext: true)
    }

    private func insertCore(_ text: String, adjustToContext: Bool) async throws -> InjectionResult {
        // Dictating into one of our OWN windows (onboarding playground,
        // settings fields): every AX call below would target our own process
        // and deadlock against our own main thread. Synthesized keystrokes
        // via the HID tap are the only safe path — take it directly.
        let ownWindow = await MainActor.run { FocusOwnership.ownWindowFocused }
        if ownWindow {
            log.debug("target is our own window — typing directly, no AX")
            return try await fallback.insert(text)
        }

        let insertStart = CFAbsoluteTimeGetCurrent()

        // Ask the AX tree FIRST, and only coax when it doesn't answer with an
        // editable target. The coax (AXEnhancedUserInterface) forces
        // Chromium/Electron/web views to build their complete accessibility
        // tree — on content-heavy documents that costs whole seconds, and we
        // used to pay it on EVERY insertion. Native apps answer without it;
        // dormant Electron trees get coaxed exactly once per process.
        // Per-app override for the frontmost app, if the user configured one.
        let override = await MainActor.run { () -> SettingsStore.InsertionMethod? in
            guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                  let raw = SettingsStore.shared.insertionOverrides[bundleID] else { return nil }
            return SettingsStore.InsertionMethod(rawValue: raw)
        }
        // Secure Keyboard Entry (terminals, password prompts) silently drops
        // synthesized keystrokes and ⌘V. AX writes still land, so the ladder
        // proceeds — but any path that would END at synthetic input ends at
        // the clipboard instead, and the "Copied" hint tells the user to
        // paste manually.
        let secureInput = IsSecureEventInputEnabled()

        var verdict = Self.focusedElementVerdict()
        if verdict != .editable, Self.coaxFrontmostAppAXIfNeeded() {
            verdict = Self.focusedElementVerdict()
        }

        switch verdict {
        case .editable:
            break // continue to the AX → keystroke insertion flow below

        case .opaqueApp:
            // The focused app refuses to answer accessibility queries at all
            // (dormant/none Electron tree, some cross-platform toolkits). We
            // can't know what's focused — but the user pressed the hotkey
            // with a caret somewhere, and synthetic input doesn't need the
            // AX tree.
            if secureInput {
                log.info("AX-opaque app under secure input — copying only")
                return try Self.copyToClipboard(text)
            }
            if override == .paste {
                log.info("AX-opaque app, per-app override — pasting")
                return try await paste.insert(text)
            }
            log.debug("focused app is AX-opaque — typing keystrokes directly")
            return try await fallback.insert(text)

        case .notEditable:
            // AX answered and the focus is genuinely not a text input — a
            // button, a Finder window, a read-only view. Typing here would
            // spray keystrokes into shortcut handlers; copy instead.
            log.debug("no text-editable focused; copying to clipboard only")
            return try Self.copyToClipboard(text)
        }

        var adjusted = text
        if adjustToContext {
            let context = Self.fieldContextBeforeCursor()
            // Case first (needs the text's first letter), then space.
            adjusted = Self.smartCased(text, afterMeaningful: context.lastMeaningful)
            adjusted = Self.smartSpaced(adjusted, afterPrevious: context.immediate)
        }

        // User pinned this app to a specific method — honor it (secure input
        // permitting; under secure input the ladder below ends in a copy).
        if !secureInput, let override {
            switch override {
            case .paste:
                log.info("per-app override — pasting")
                return try await paste.insert(adjusted)
            case .type:
                log.info("per-app override — typing keystrokes")
                return try await fallback.insert(adjusted)
            }
        }

        let useAX = await MainActor.run { SettingsStore.shared.axInsertionEnabled }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let axBlocked = frontmostBundleID.map(Self.axBlacklistedBundleIDs.contains) ?? false
        if useAX && !axBlocked {
            do {
                let result = try await primary.insert(adjusted)
                log.info("AX injection succeeded in \(Self.elapsedMs(since: insertStart))ms")
                return result
            } catch {
                log.info("AX injection failed after \(Self.elapsedMs(since: insertStart))ms (\(String(describing: error))) — falling back to synthesized keystrokes")
            }
        } else if axBlocked {
            log.debug("AX skipped for known-bad bundle \(frontmostBundleID ?? "?") — using synthesized keystrokes")
        }
        if secureInput {
            log.info("secure input active — synthetic keystrokes would be dropped; copying only")
            return try Self.copyToClipboard(adjusted)
        }
        let result = try await fallback.insert(adjusted)
        log.info("keystroke injection finished at \(Self.elapsedMs(since: insertStart))ms total")
        return result
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
    private static func copyToClipboard(_ text: String) throws -> InjectionResult {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InjectionError.clipboardFailed
        }
        return .copied
    }

    /// PIDs already coaxed this session. Re-setting the attributes is wasted
    /// IPC, and AXEnhancedUserInterface in particular can retrigger expensive
    /// accessibility-tree work in web views. Both attributes stick for the
    /// lifetime of the target process, so once is enough.
    private static let coaxedPids = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])

    /// Wakes up the front app's AX tree if it's an Electron/Chromium host —
    /// their accessibility trees are dormant by default and refuse to expose
    /// text-input roles until these attributes are set. Returns true when the
    /// coax was actually performed (first time for this process), so the
    /// caller knows a re-query is worthwhile.
    @discardableResult
    private static func coaxFrontmostAppAXIfNeeded() -> Bool {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return false }
        let firstTime = coaxedPids.withLock { $0.insert(pid).inserted }
        guard firstTime else { return false }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, true as CFTypeRef)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, true as CFTypeRef)
        return true
    }

    private static func elapsedMs(since start: CFAbsoluteTime) -> Int {
        Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
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

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef else { return FieldContext() }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.location > 0 else {
            return FieldContext()
        }

        // Read only a small window before the caret. A parameterized range
        // read is O(window); reading kAXValue serializes the entire document
        // over IPC — visibly slow when dictating into large existing text.
        let window = min(16, range.location)
        var span = CFRange(location: range.location - window, length: window)
        if let axSpan = AXValueCreate(.cfRange, &span) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                axElement, kAXStringForRangeParameterizedAttribute as CFString, axSpan, &out
            ) == .success, let windowText = out as? String, !windowText.isEmpty {
                return contextFrom(prefix: windowText)
            }
        }

        // Fallback for elements without parameterized text support: the old
        // full-value read.
        var valueRef: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &valueRef)
        guard let value = valueRef as? String, !value.isEmpty else { return FieldContext() }
        let cursor = max(0, min(value.count, range.location))
        guard cursor > 0 else { return FieldContext() }
        return contextFrom(prefix: String(value.prefix(cursor)))
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
