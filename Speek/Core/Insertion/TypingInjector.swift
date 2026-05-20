import AppKit

/// Synthesizes the transcribed text as raw keyboard events using
/// `CGEvent.keyboardSetUnicodeString`. The OS treats these as if the user typed
/// them — works in virtually any app that accepts keyboard input, including
/// Messages, Electron-based apps (Slack, Discord, VS Code, Cursor), web inputs,
/// and custom Cocoa text views that reject AX writes and ⌘V paste.
///
/// This is the same approach Whispr Flow and similar dictation tools use, and
/// is strictly more universal than clipboard-paste because it doesn't rely on
/// the destination app handling the paste shortcut — it relies only on the app
/// accepting keyboard input, which is fundamental.
final class TypingInjector: TextInjector {
    /// macOS caps `keyboardSetUnicodeString` at 20 UTF-16 characters per event.
    /// Longer text has to be split across multiple events.
    private static let maxCharactersPerEvent = 20

    func insert(_ text: String) async throws -> InjectionResult {
        guard !text.isEmpty else { return .inserted }
        let src = CGEventSource(stateID: .combinedSessionState)
        let utf16 = Array(text.utf16)
        var index = 0
        while index < utf16.count {
            let chunkSize = Swift.min(Self.maxCharactersPerEvent, utf16.count - index)
            let chunk = Array(utf16[index..<(index + chunkSize)])
            guard let event = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) else {
                throw InjectionError.unsupportedTarget
            }
            chunk.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                }
            }
            event.post(tap: .cghidEventTap)
            index += chunkSize
            if index < utf16.count {
                // Brief pause so the destination app's run loop has a chance
                // to process each chunk in order.
                try await Task.sleep(nanoseconds: 4_000_000) // 4ms
            }
        }
        return .inserted
    }
}
