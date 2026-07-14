import AppKit

/// CleanShot-style "drag to authorize" helper: a small floating card showing
/// Speek's app icon that the user can drag directly into a System Settings
/// permission list (Accessibility, Input Monitoring). Dropping an app bundle
/// onto those lists registers it instantly — one motion replaces the
/// +-button/file-picker expedition, and re-dropping replaces stale entries.
///
/// The card follows the System Settings window and dismisses itself when
/// Settings closes or the caller hides it (permission granted, step change).
@MainActor
final class DragAuthorizePanelController {
    static let shared = DragAuthorizePanelController()

    private var panel: NSPanel?
    private var trackTask: Task<Void, Never>?
    /// Settings can take a couple of seconds to appear after the deep-link;
    /// don't give up before it was ever seen.
    private let settingsAppearanceGrace: TimeInterval = 6

    private init() {}

    func show() {
        if panel == nil { buildPanel() }
        panel?.orderFrontRegardless()
        startTracking()
    }

    func hide() {
        trackTask?.cancel()
        trackTask = nil
        panel?.orderOut(nil)
    }

    // MARK: - Panel

    private func buildPanel() {
        let size = NSSize(width: 224, height: 180)
        let content = DragAuthorizeContentView(frame: NSRect(origin: .zero, size: size))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        panel.isMovableByWindowBackground = true
        self.panel = panel
    }

    // MARK: - System Settings window tracking

    private func startTracking() {
        trackTask?.cancel()
        let grace = settingsAppearanceGrace
        trackTask = Task { [weak self] in
            var seenSettings = false
            let start = Date()
            while !Task.isCancelled {
                guard let self else { return }
                if self.positionNextToSystemSettings() {
                    seenSettings = true
                } else if seenSettings || Date().timeIntervalSince(start) > grace {
                    // Settings closed (or never appeared) — retire the card.
                    self.hide()
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Places the card beside the System Settings window. Returns false when
    /// no Settings window is on screen.
    private func positionNextToSystemSettings() -> Bool {
        guard let settings = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
            !settings.isTerminated else { return false }

        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == settings.processIdentifier
                && (($0[kCGWindowLayer as String] as? Int) ?? 1) == 0
        }),
            let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
            let x = bounds["X"], let y = bounds["Y"],
            let width = bounds["Width"], let height = bounds["Height"],
            let panel, let primary = NSScreen.screens.first else { return false }

        // CG coordinates are top-left-origin on the primary display; Cocoa is
        // bottom-left. Convert the Settings window's top edge.
        let cocoaTop = primary.frame.maxY - y

        // Prefer the left flank; fall back to the right edge of the window.
        var px = x - panel.frame.width - 24
        if px < (primary.visibleFrame.minX + 8) {
            px = x + width + 24
        }
        let py = cocoaTop - height / 2 - panel.frame.height / 2  // vertical middle
        panel.setFrameOrigin(NSPoint(x: px, y: py))
        return true
    }
}

// MARK: - Card content (drag source)

private final class DragAuthorizeContentView: NSView, NSDraggingSource {
    private let appIcon: NSImage = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

    private var iconRect: NSRect {
        NSRect(x: (bounds.width - 72) / 2, y: bounds.height - 96, width: 72, height: 72)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func draw(_ dirtyRect: NSRect) {
        // Card background.
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 16, yRadius: 16)
        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        card.fill()
        NSColor.separatorColor.setStroke()
        card.lineWidth = 1
        card.stroke()

        appIcon.draw(in: iconRect)

        let title = "Drag me into the list" as NSString
        let caption = "Drop the icon onto the permission list\nin System Settings, then toggle on." as NSString

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: Self.centered
        ]
        let captionAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: Self.centered
        ]
        title.draw(in: NSRect(x: 8, y: bounds.height - 122, width: bounds.width - 16, height: 18), withAttributes: titleAttrs)
        caption.draw(in: NSRect(x: 10, y: bounds.height - 158, width: bounds.width - 20, height: 32), withAttributes: captionAttrs)
    }

    private static let centered: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        return p
    }()

    override func mouseDown(with event: NSEvent) {
        // Serve the app bundle as a file-URL drag — System Settings'
        // permission lists accept dropped app bundles.
        let draggingItem = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        draggingItem.setDraggingFrame(iconRect, contents: appIcon)
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    nonisolated func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
}
