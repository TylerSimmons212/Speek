import AppKit

final class ClipboardInjector: TextInjector {
    func insert(_ text: String) async throws -> InjectionResult {
        let pb = NSPasteboard.general

        // Write the new text. We intentionally don't preserve/restore the
        // previous clipboard contents: if Cmd-V silently fails (because the
        // app we're firing into isn't actually a paste target), restoring
        // would wipe the transcription. Keeping the speech on the clipboard
        // means a manual ⌘V always works as a fallback.
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

        // We fired Cmd-V but can't reliably tell whether the destination
        // accepted it. Report .copied — the text is definitely on the
        // clipboard, so the user can always paste manually if the auto-paste
        // didn't land. Honest signal beats a misleading "Inserted" message.
        return .copied
    }
}
