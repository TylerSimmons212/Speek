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
    private var notchOverlay: NotchOverlayController?
    private var onboarding: OnboardingWindowController?
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

        // Only auto-prompt on launch AFTER onboarding: during first run the
        // wizard owns the permission flow — its Grant buttons trigger each
        // prompt when the user is ready, not all three the moment the app
        // opens. (Post-onboarding, the OS shows the Input Monitoring modal
        // once per app version; the Accessibility modal re-appears while the
        // process is untrusted — both desired when genuinely ungranted.)
        if SettingsStore.shared.onboardingCompleted {
            if !perms.hasMic { await perms.requestMic() }
            if !perms.hasAccessibility { perms.requestAccessibility() }
            if !perms.hasInputMonitoring { perms.requestInputMonitoring() }
        }

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

        // Rebuild the pipeline whenever anything it derives from changes:
        // custom vocabulary, polish engine/mode, or LLM connection details.
        let settings = SettingsStore.shared
        Publishers.MergeMany(
            settings.$customReplacements.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$polishEngine.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$polishMode.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$llmEndpoint.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$llmModel.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$llmAPIKey.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.session?.pipeline = Self.makePipeline(with: SettingsStore.shared.customReplacements)
        }
        .store(in: &cancellables)
        self.menuBar = MenuBarController(session: session)
        buildOverlay(style: SettingsStore.shared.overlayStyle, session: session)

        // Start Sparkle's background update-check cycle.
        _ = UpdaterService.shared

        // Pause music while recording; resume the moment recording ends
        // (processing/inserting don't need silence).
        session.$state
            .removeDuplicates()
            .sink { state in
                if state == .recording {
                    MediaPauseService.shared.pausePlayingApps()
                } else {
                    MediaPauseService.shared.resumePausedApps()
                }
            }
            .store(in: &cancellables)

        // First-run onboarding. The hotkey tap starts when the user clears
        // the permissions step, so the tryout step actually works.
        if !SettingsStore.shared.onboardingCompleted {
            onboarding = OnboardingWindowController(
                session: session,
                onPermissionsGranted: { [weak self] in self?.hotkey.start() }
            )
            onboarding?.show()
        }

        // Swap the overlay live when the user changes the style in Settings.
        SettingsStore.shared.$overlayStyle
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] style in
                guard let self, let session = self.session else { return }
                self.buildOverlay(style: style, session: session)
            }
            .store(in: &cancellables)

        hotkey.configure(binding: SettingsStore.shared.hotkeyBinding)
        hotkey.events
            .sink { [weak self] event in self?.handle(event: event, session: session) }
            .store(in: &cancellables)
        // Creating the CGEventTap is itself what triggers the Input Monitoring
        // permission prompt — so during first-run onboarding, defer it until
        // the user passes the permissions step (see callback below).
        if SettingsStore.shared.onboardingCompleted {
            hotkey.start()
        }

        // Re-apply the hotkey binding whenever the user changes it (Settings
        // or the onboarding hotkey step).
        SettingsStore.shared.$hotkeyBinding
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] binding in
                guard let self else { return }
                // Restart only if the tap was already live — during early
                // onboarding it isn't yet (starts at the permissions step),
                // and starting it here would fire the permission prompt.
                let wasRunning = self.hotkey.isRunning
                self.hotkey.stop()
                self.hotkey.configure(binding: binding)
                if wasRunning { self.hotkey.start() }
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
        let settings = SettingsStore.shared
        let polish: any PolishStage
        switch settings.polishEngine {
        case .off:
            polish = NullPolishStage()
        case .appleIntelligence:
            polish = FMPolishStage()
        case .customLLM:
            polish = LLMPolishStage(config: .init(
                endpoint: settings.llmEndpoint,
                model: settings.llmModel,
                apiKey: settings.llmAPIKey
            ))
        }
        return FormattingPipeline(
            rule: RuleStage(customReplacements: vocabulary),
            polish: polish,
            mode: settings.polishMode
        )
    }

    /// Tears down whichever overlay is active and builds the requested style.
    private func buildOverlay(style: SettingsStore.OverlayStyle, session: DictationSession) {
        overlay?.close()
        overlay = nil
        notchOverlay?.dismiss()
        notchOverlay = nil
        switch style {
        case .notch:
            notchOverlay = NotchOverlayController(session: session)
        case .bottomPill:
            overlay = RecordingOverlayWindow(session: session)
        }
    }

    private func handle(event: HotkeyManager.Event, session: DictationSession) {
        switch event {
        case .pressed:
            if toggleLocked {
                // Latched recording: the decision to stop happens on RELEASE
                // (and only for a clean press), so that using the trigger key
                // in a chord (Fn+arrow, Right-Option+letter) mid-recording
                // doesn't end the session.
                return
            }
            pressStartTime = Date()
            session.startRecording()

        case .released(let clean):
            if toggleLocked {
                guard clean else { return } // chord while latched — keep going
                toggleLocked = false
                lastShortReleaseTime = nil
                pressStartTime = nil
                Task { await session.stopRecording() }
                return
            }

            guard let pressed = pressStartTime else { return }
            pressStartTime = nil
            let duration = Date().timeIntervalSince(pressed)

            guard clean else {
                // The "hold" was actually a chord (Fn+arrow, Right-Option+E…).
                // The user was typing, not dictating — discard the recording.
                lastShortReleaseTime = nil
                Task { await session.cancelRecording() }
                return
            }

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
