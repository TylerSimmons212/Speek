import AppKit

/// Inserts text by putting it on the general pasteboard and synthesizing ⌘V,
/// then restoring the previous pasteboard contents shortly after. The most
/// compatible path for Electron/web apps whose AX text writes silently fail —
/// and the default method of most commercial dictation tools. Used only via
/// per-app overrides (Settings → Insertion); the AX-first ladder stays the
/// global default because it never touches the clipboard.
final class PasteInjector: TextInjector {
    /// Delay before restoring the clipboard: long enough for the target app
    /// to consume the paste (slow Electron apps included), short enough that
    /// a subsequent user copy is unlikely to land inside it. Restore is
    /// skipped entirely if anything else claimed the pasteboard meanwhile.
    private let restoreDelay: TimeInterval = 1.5

    func insert(_ text: String) async throws -> InjectionResult {
        guard !text.isEmpty else { return .inserted }
        // A still-held modifier would turn ⌘V into a bigger chord.
        await TypingInjector.waitForModifierRelease()

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw InjectionError.clipboardFailed
        }
        let ourChangeCount = pasteboard.changeCount

        Self.synthesizeCmdV()

        // Restore off the critical path — the caller shouldn't wait on it.
        let delay = restoreDelay
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            let pasteboard = NSPasteboard.general
            // Only restore if nothing else claimed the pasteboard since.
            guard pasteboard.changeCount == ourChangeCount else { return }
            pasteboard.clearContents()
            Self.restore(saved, to: pasteboard)
        }
        return .inserted
    }

    // MARK: - Pasteboard snapshot/restore (parameterized for testability)

    static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
        }
    }

    static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func synthesizeCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else {
            return
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
