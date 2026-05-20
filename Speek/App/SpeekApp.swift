import SwiftUI
import AppKit
import Combine

@main
struct SpeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // No SwiftUI Settings scene — `showSettingsWindow:` no longer opens it
    // reliably on macOS 26 for accessory apps. The menubar item opens its own
    // NSWindow hosting SettingsView via SettingsWindowController.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyManager()
    private let audio = AudioCaptureService()
    private let perms = PermissionsCoordinator.shared
    private var transcriber: ParakeetEngine?
    private var session: DictationSession?
    private var menuBar: MenuBarController?
    private var overlay: RecordingOverlayWindow?
    private var cancellables = Set<AnyCancellable>()
    /// Press timestamp for the current key press, used to classify hold vs tap.
    private var pressStartTime: Date?
    /// Release timestamp of the last short tap; used for double-tap detection.
    private var lastShortReleaseTime: Date?
    /// True while we're in "double-tap toggle" mode: recording stays on until
    /// the user presses the key again to end it.
    private var toggleLocked = false
    /// Below this, treat the press+release as a tap (not a PTT hold).
    private let shortTapThreshold: TimeInterval = 0.2
    /// Two short taps within this window are interpreted as a double-tap.
    private let doubleTapWindow: TimeInterval = 0.5

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            await self.setUp()
        }
    }

    @MainActor
    private func setUp() async {
        perms.refresh()
        if !perms.hasMic { await perms.requestMic() }

        // Prompt each launch if not yet granted. The OS only shows the modal once
        // per app version for Input Monitoring; subsequent calls no-op silently.
        // For Accessibility, the modal re-appears whenever the process is untrusted,
        // which is the desired behavior when the user genuinely hasn't granted it.
        if !perms.hasAccessibility { perms.requestAccessibility() }
        if !perms.hasInputMonitoring { perms.requestInputMonitoring() }

        perms.refresh()
        NSLog("Speek permissions — mic: \(perms.hasMic), accessibility: \(perms.hasAccessibility), inputMonitoring: \(perms.hasInputMonitoring), foundationModels: \(perms.hasFoundationModels)")

        // Load Parakeet (model download on first launch).
        do {
            self.transcriber = try await ParakeetEngine()
        } catch {
            print("Parakeet load failed: \(error)")
        }

        // Build the session with whatever transcriber loaded — if Parakeet failed,
        // session remains nil and hotkey events are ignored. Future task can
        // surface the load failure in the UI.
        guard let transcriber = self.transcriber else { return }

        let session = DictationSession(
            audio: audio,
            transcriber: transcriber,
            pipeline: Self.makePipeline(with: SettingsStore.shared.customReplacements),
            injector: CompositeInjector()
        )
        self.session = session

        // Rebuild the pipeline whenever the user edits their custom vocabulary.
        SettingsStore.shared.$customReplacements
            .dropFirst()
            .sink { [weak self] vocab in
                self?.session?.pipeline = Self.makePipeline(with: vocab)
            }
            .store(in: &cancellables)
        self.menuBar = MenuBarController(session: session)
        self.overlay = RecordingOverlayWindow(session: session)

        hotkey.configure(for: SettingsStore.shared.hotkeyChoice)
        hotkey.events
            .sink { [weak self] event in self?.handle(event: event, session: session) }
            .store(in: &cancellables)
        hotkey.start()

        // Re-apply the hotkey choice whenever the user changes it in Settings.
        SettingsStore.shared.$hotkeyChoice
            .dropFirst()
            .sink { [weak self] choice in
                guard let self else { return }
                self.hotkey.stop()
                self.hotkey.configure(for: choice)
                self.hotkey.start()
            }
            .store(in: &cancellables)
    }

    /// Unified hotkey handler — both push-to-talk and double-tap-toggle modes
    /// are active simultaneously. We use the duration between press and release
    /// to classify:
    ///   - Long press (≥ shortTapThreshold) → push-to-talk: record while held.
    ///   - Short press (< shortTapThreshold) → tap. Two taps within
    ///     doubleTapWindow latch the recording on (toggle mode); a single tap
    ///     in isolation is treated as accidental and the brief recording is
    ///     discarded (no transcription).
    ///   - Any press while latched in toggle mode ends the recording.
    private static func makePipeline(with vocabulary: [String: String]) -> FormattingPipeline {
        FormattingPipeline(
            rule: RuleStage(customReplacements: vocabulary),
            polish: FMPolishStage()
        )
    }

    private func handle(event: HotkeyManager.Event, session: DictationSession) {
        switch event {
        case .pressed:
            if toggleLocked {
                // Press during toggle-recording ends the session.
                toggleLocked = false
                lastShortReleaseTime = nil
                pressStartTime = nil
                Task { await session.stopRecording() }
                return
            }
            pressStartTime = Date()
            session.startRecording()
        case .released:
            guard let pressed = pressStartTime else { return }
            pressStartTime = nil
            let duration = Date().timeIntervalSince(pressed)

            if duration >= shortTapThreshold {
                // Genuine push-to-talk hold — stop and transcribe.
                Task { await session.stopRecording() }
                lastShortReleaseTime = nil
                return
            }

            // Short tap. Was the previous release also a short tap inside the window?
            let now = Date()
            if let lastRelease = lastShortReleaseTime,
               now.timeIntervalSince(lastRelease) < doubleTapWindow {
                // DOUBLE-TAP detected — latch into toggle-recording.
                toggleLocked = true
                lastShortReleaseTime = nil
                // Recording is already running from the second press; let it continue.
                return
            }
            // Single short tap — discard the negligible audio so Parakeet
            // doesn't error on an empty buffer. Wait for a possible second tap.
            lastShortReleaseTime = now
            Task { await session.cancelRecording() }
        }
    }
}
