import AppKit

final class ClipboardInjector: TextInjector {
    func insert(_ text: String) async throws {
        let pb = NSPasteboard.general

        // Save existing clipboard contents (string only — we don't bother with rich types).
        let saved = pb.string(forType: .string)

        // Write the new text.
        pb.clearContents()
        guard pb.setString(text, forType: .string) else {
            throw InjectionError.clipboardFailed
        }

        // Brief delay so target app sees the new pasteboard.
        try await Task.sleep(nanoseconds: 30_000_000) // 30ms

        // Fire Cmd-V via CGEvent.
        let src = CGEventSource(stateID: .combinedSessionState)
        let cmdDown = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) // V
        cmdDown?.flags = .maskCommand
        let cmdUp = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        cmdUp?.flags = .maskCommand
        cmdDown?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)

        // Wait long enough for the paste to land before restoring.
        try await Task.sleep(nanoseconds: 80_000_000) // 80ms

        // Restore old clipboard.
        pb.clearContents()
        if let saved {
            pb.setString(saved, forType: .string)
        }
    }
}
