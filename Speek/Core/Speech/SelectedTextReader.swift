import AppKit
import ApplicationServices

/// Grabs the user's current text selection from the frontmost app.
/// Two paths, tried in order:
///  1. Accessibility — kAXSelectedText on the focused element. Instant, no
///     side effects; works in native apps.
///  2. Clipboard fallback — synthesizes ⌘C targeted at the app's PID, waits
///     for the pasteboard to change, then restores whatever was on it.
///     Needed for AX-opaque apps (Electron, some browser web areas).
@MainActor
final class SelectedTextReader {
    static let shared = SelectedTextReader()

    /// The most recent non-Speek app the user was in, tracked so triggers
    /// that pass through our own UI (the menu bar item) still know which app
    /// holds the selection after our menu steals activation.
    private(set) var lastExternalApp: NSRunningApplication?
    private var observer: NSObjectProtocol?

    private init() {
        lastExternalApp = NSWorkspace.shared.frontmostApplication.flatMap {
            $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    /// Returns the selected text in the frontmost app, or nil if there is no
    /// usable selection. May take up to ~1s in the clipboard-fallback case.
    func captureSelection() async -> String? {
        // Self-AX deadlocks — never query our own windows (and our own UI has
        // nothing worth reading aloud anyway).
        if !FocusOwnership.ownWindowFocused,
           let text = Self.axSelectedText(),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        return await clipboardFallback()
    }

    // MARK: - AX path

    private static func axSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let f = focused else { return nil }
        // swiftlint:disable:next force_cast
        let element = f as! AXUIElement

        // Never read secure fields.
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
        if (subroleRef as? String) == (kAXSecureTextFieldSubrole as String) { return nil }

        var selectedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedRef) == .success,
              let text = selectedRef as? String else { return nil }
        return text
    }

    // MARK: - Clipboard fallback

    private func clipboardFallback() async -> String? {
        guard let target = lastExternalApp ?? NSWorkspace.shared.frontmostApplication,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }

        let pasteboard = NSPasteboard.general
        let saved = Self.snapshot(of: pasteboard)
        let before = pasteboard.changeCount

        // The user may still be holding the trigger key — a synthetic ⌘C
        // while (say) Fn is down could become a different chord entirely.
        await Self.waitForModifierRelease()
        Self.postCopyChord(to: target.processIdentifier)

        var copied: String?
        for _ in 0..<30 {  // up to ~600ms; no selection = no pasteboard change
            try? await Task.sleep(nanoseconds: 20_000_000)
            if pasteboard.changeCount != before {
                // Small settle for promised/lazy pasteboard data.
                try? await Task.sleep(nanoseconds: 30_000_000)
                copied = pasteboard.string(forType: .string)
                break
            }
        }
        if pasteboard.changeCount != before {
            Self.restore(saved, to: pasteboard)
        }
        let trimmed = copied?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? copied : nil
    }

    private static func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        }
    }

    private static func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    private static func postCopyChord(to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCodeC: CGKeyCode = 8
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: keyCodeC, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
    }

    private static func waitForModifierRelease() async {
        let mask: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        for _ in 0..<66 {  // ~1s cap
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(mask).isEmpty { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }
}
