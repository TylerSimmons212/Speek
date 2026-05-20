import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingOverlayWindow {
    private let panel: NSPanel
    private var cancellables = Set<AnyCancellable>()

    init(session: DictationSession) {
        let host = NSHostingController(rootView: RecordingOverlayView(session: session))
        // Wide panel so the "Learned …" pill can grow as wide as it needs to.
        // The panel itself is transparent; only the capsule inside is visible.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 44),
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

        // Accept mouse events only while the "learned" pill is up so its undo
        // button is clickable. The recording pill stays click-through.
        CorrectionLearner.shared.$lastLearned
            .map { $0 == nil }
            .removeDuplicates()
            .sink { [weak self] ignore in
                self?.panel.ignoresMouseEvents = ignore
            }
            .store(in: &cancellables)

        // Reposition each time recording (or a learned-feedback notification)
        // becomes visible, so the pill always lands on the user's current
        // screen — important for multi-monitor setups and resolution changes.
        session.$state
            .sink { [weak self] state in
                if state != .idle { self?.positionBottomCenter() }
            }
            .store(in: &cancellables)
        CorrectionLearner.shared.$lastLearned
            .compactMap { $0 }
            .sink { [weak self] _ in self?.positionBottomCenter() }
            .store(in: &cancellables)

        // Also catch external screen geometry changes (display added/removed,
        // resolution change, Dock visibility toggle, etc.).
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.positionBottomCenter() }
            .store(in: &cancellables)
    }

    /// Centers the pill horizontally on whichever screen currently contains
    /// the mouse cursor (falling back to `NSScreen.main` if we can't tell).
    private func positionBottomCenter() {
        let target = screenUnderCursor() ?? NSScreen.main
        guard let screen = target else { return }
        let visible = screen.visibleFrame
        let frame = panel.frame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 40
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func screenUnderCursor() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
    }
}
