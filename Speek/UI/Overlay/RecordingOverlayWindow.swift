import AppKit
import SwiftUI

@MainActor
final class RecordingOverlayWindow {
    private let panel: NSPanel

    init(session: DictationSession) {
        let host = NSHostingController(rootView: RecordingOverlayView(session: session))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentViewController = host
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        self.panel = panel
        positionBottomCenter()
        panel.orderFront(nil)
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        let x = screen.frame.midX - frame.width / 2
        let y = screen.visibleFrame.minY + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
