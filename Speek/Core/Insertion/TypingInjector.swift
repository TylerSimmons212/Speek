import AppKit
import ApplicationServices

/// Synthesizes the transcribed text as raw keyboard events using
/// `CGEvent.keyboardSetUnicodeString`. The OS treats these as if the user typed
/// them — works in virtually any app that accepts keyboard input, including
/// Messages, Electron-based apps (Slack, Discord, VS Code, Cursor), web inputs,
/// and custom Cocoa text views that reject AX writes and ⌘V paste.
///
/// Events are posted directly to the focused element's process when it can be
/// determined (more reliable than the HID tap when focus is in a floating
/// panel or the frontmost app changed mid-transcription), falling back to the
/// system-wide HID tap otherwise.
final class TypingInjector: TextInjector {
    /// UTF-16 units per keyboard event. Large chunks keep long dictations fast
    /// (one event pair per 200 units instead of per 20); production dictation
    /// tools ship the same size.
    static let maxUnitsPerEvent = 200

    /// How long to wait for the user to release all modifier keys before
    /// typing. If a modifier (Fn, ⌘, ⌥…) is still physically held when the
    /// synthesized events arrive, the target app interprets the text as a
    /// storm of keyboard shortcuts instead of characters.
    private static let modifierWaitTimeout: TimeInterval = 3
    private static let modifierPollInterval: TimeInterval = 0.015

    func insert(_ text: String) async throws -> InjectionResult {
        guard !text.isEmpty else { return .inserted }

        await Self.waitForModifierRelease()

        let src = CGEventSource(stateID: .combinedSessionState)
        // The PID lookup is an AX query against the focused element — skip it
        // when focus is in our own app (self-AX deadlocks) and post through
        // the HID tap, which the system routes to our focused window anyway.
        let ownWindow = await MainActor.run { FocusOwnership.ownWindowFocused }
        let targetPid = ownWindow ? nil : Self.focusedElementPid()
        let utf16 = Array(text.utf16)

        for range in Self.chunkRanges(for: utf16, maxLength: Self.maxUnitsPerEvent) {
            let chunk = Array(utf16[range])
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else {
                throw InjectionError.unsupportedTarget
            }
            chunk.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                }
            }
            if let pid = targetPid {
                event.postToPid(pid)
            } else {
                event.post(tap: .cghidEventTap)
            }
            if range.upperBound < utf16.count {
                // Brief pause so the destination app's run loop has a chance
                // to process each chunk in order.
                try await Task.sleep(nanoseconds: 4_000_000) // 4ms
            }
        }
        return .inserted
    }

    /// Splits `utf16` into ranges of at most `maxLength` units, never splitting
    /// a surrogate pair: if a range would end between a high and low surrogate,
    /// the boundary backs off by one so the pair travels in the same event.
    /// A split pair would arrive at the target app as two lone surrogates and
    /// corrupt any emoji or non-BMP character sitting on a chunk boundary.
    static func chunkRanges(for utf16: [UInt16], maxLength: Int) -> [Range<Int>] {
        guard !utf16.isEmpty, maxLength > 1 else {
            return utf16.isEmpty ? [] : [0..<utf16.count]
        }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < utf16.count {
            var end = Swift.min(start + maxLength, utf16.count)
            // Don't end on a high surrogate whose low surrogate is next.
            if end < utf16.count, Self.isHighSurrogate(utf16[end - 1]), Self.isLowSurrogate(utf16[end]) {
                end -= 1
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    static func isHighSurrogate(_ unit: UInt16) -> Bool { (0xD800...0xDBFF).contains(unit) }
    static func isLowSurrogate(_ unit: UInt16) -> Bool { (0xDC00...0xDFFF).contains(unit) }

    /// PID of the process owning the focused AX element, if discoverable.
    /// Preferred over `NSWorkspace.frontmostApplication` because the focused
    /// element is what will actually receive the keystrokes — they can differ
    /// when a non-activating panel or launcher holds keyboard focus.
    private static func focusedElementPid() -> pid_t? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement
        var pid: pid_t = 0
        guard AXUIElementGetPid(axElement, &pid) == .success, pid > 0 else { return nil }
        return pid
    }

    /// Polls until no modifier flags are held, or the timeout elapses. The
    /// timeout path proceeds anyway — typing with a stuck modifier is still
    /// better than silently dropping the user's dictation.
    private static func waitForModifierRelease() async {
        let interesting: CGEventFlags = [
            .maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn
        ]
        let deadline = Date().addingTimeInterval(modifierWaitTimeout)
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(interesting).isEmpty { return }
            try? await Task.sleep(nanoseconds: UInt64(modifierPollInterval * 1_000_000_000))
        }
    }
}
