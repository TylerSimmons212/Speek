import AppKit

extension NSWindow {
    /// Centers the window on the screen the user is actually working on —
    /// the one containing the mouse — rather than whatever AppKit considers
    /// the main screen. `NSWindow.center()` also sits windows noticeably
    /// above true center; this puts them dead center of the visible frame.
    func centerOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.midY - frame.height / 2
        ))
    }
}
