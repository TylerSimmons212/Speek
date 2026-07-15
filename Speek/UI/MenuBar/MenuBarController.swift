import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let settingsWindow = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()
    private weak var meetingItem: NSMenuItem?

    init(session: DictationSession) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Speek")
        }

        let menu = NSMenu()
        let meetingItem = NSMenuItem(title: "Transcribe Meeting Audio", action: #selector(toggleMeetingTranscription), keyEquivalent: "")
        meetingItem.target = self
        menu.addItem(meetingItem)
        self.meetingItem = meetingItem
        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updatesItem.target = self
        menu.addItem(updatesItem)
        menu.addItem(NSMenuItem.separator())
        // Leave Quit's target = nil so the action routes up the responder
        // chain to NSApplication (which implements terminate:). Setting
        // target = self would force macOS to validate the selector against
        // this controller and disable the item.
        menu.addItem(NSMenuItem(title: "Quit Speek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        session.$state
            .sink { [weak self] state in self?.updateIcon(for: state) }
            .store(in: &cancellables)

        MeetingTranscriptionService.shared.$state
            .sink { [weak self] state in
                switch state {
                case .listening:
                    self?.meetingItem?.title = "Stop Transcribing Meeting"
                case .idle:
                    self?.meetingItem?.title = "Transcribe Meeting Audio"
                case .failed(let message):
                    self?.meetingItem?.title = "Transcribe Meeting Audio"
                    NSLog("MeetingTranscription failed: \(message)")
                }
            }
            .store(in: &cancellables)
    }

    @objc private func toggleMeetingTranscription() {
        let service = MeetingTranscriptionService.shared
        if service.isListening {
            Task { @MainActor in
                if let url = await service.stop() {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            return
        }

        // One-time consent note: a silent system-level listener makes call-
        // recording consent entirely the user's responsibility.
        if !SettingsStore.shared.meetingConsentAcknowledged {
            let alert = NSAlert()
            alert.messageText = "Transcribe meeting audio?"
            alert.informativeText = "Speek will transcribe all audio playing on this Mac, entirely on-device — nothing leaves your computer.\n\nRecording laws vary by location: some places require everyone on a call to consent. It's your responsibility to get consent where required."
            alert.addButton(withTitle: "Start Transcribing")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            SettingsStore.shared.meetingConsentAcknowledged = true
        }
        service.start()
    }

    private func updateIcon(for state: DictationSession.State) {
        guard let button = statusItem.button else { return }
        switch state {
        case .recording:
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Recording")
        case .processing:
            button.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "Processing")
        default:
            button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Speek")
        }
    }

    @objc private func openSettings() {
        settingsWindow.show()
    }

    @objc private func checkForUpdates() {
        UpdaterService.shared.checkForUpdates()
    }
}

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "Speek Settings"
            window.contentViewController = NSHostingController(rootView: SettingsView())
            window.isReleasedWhenClosed = false
            // Center on the user's active screen at creation; after that,
            // respect wherever they drag it (standard Mac behavior). The
            // SwiftUI hosting controller zeroes the frame until first layout,
            // so set the known content size explicitly before centering —
            // never layoutIfNeeded(), which deadlocks TextKit-hosting views.
            window.setContentSize(NSSize(width: 720, height: 520))
            window.centerOnActiveScreen()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}
