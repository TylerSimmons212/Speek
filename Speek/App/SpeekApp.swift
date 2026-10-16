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
    private var meetingIndicator: MeetingIndicatorController?
    private var speechOverlay: SpeechOverlayController?
    private var cancellables = Set<AnyCancellable>()
    private var kokoroIdleTask: Task<Void, Never>?
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
        NSLog("Speek permissions — mic: \(perms.hasMic), accessibility: \(perms.hasAccessibility), inputMonitoring: \(perms.hasInputMonitoring)")

        // Prepare the mic engine now, not on the first press (only when
        // already permitted: preparing must never be what prompts).
        if perms.hasMic {
            let audio = self.audio
            Task { await audio.prewarm() }
        }

        // Load Parakeet (model download on first launch).
        do {
            self.transcriber = try await ParakeetEngine()
        } catch {
            NSLog("Parakeet load failed: \(error)")
        }

        // Build the full UI even when the model failed to load (first launch
        // offline hits this deterministically): with no menu bar item an
        // LSUIElement app is invisible and unquittable. The stub engine
        // surfaces the failure via the session's error path on each attempt.
        let transcriber: any TranscriptionEngine =
            self.transcriber ?? UnavailableTranscriptionEngine()

        let session = DictationSession(
            audio: audio,
            transcriber: transcriber,
            pipeline: Self.makePipeline(with: SettingsStore.shared.customReplacements),
            injector: CompositeInjector()
        )
        self.session = session

        // Rebuild the pipeline whenever anything it derives from changes:
        // custom vocabulary or the polish engine.
        let settings = SettingsStore.shared
        Publishers.MergeMany(
            settings.$customReplacements.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            settings.$polishEngine.dropFirst().map { _ in () }.eraseToAnyPublisher()
        )
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] in
            self?.session?.pipeline = Self.makePipeline(with: SettingsStore.shared.customReplacements)
            Self.applyPolishEngineChange()
        }
        .store(in: &cancellables)

        // Apple speech assets for the live preview tier (system-managed
        // download; no-op once installed).
        Task { await SpeechPreviewEngine.shared.prepare() }

        // s1-mini: fetch weights if needed and pre-load so the first
        // dictation doesn't pay the model-load cost. When the download
        // finishes (first launch), load then too.
        if settings.polishEngine == .s1Mini {
            S1ModelStore.shared.ensureDownloaded()
        }
        S1ModelStore.shared.$state
            .filter { $0 == .ready }
            .sink { _ in
                guard SettingsStore.shared.polishEngine == .s1Mini else { return }
                Task { await S1PolishStage.shared.prepare() }
            }
            .store(in: &cancellables)
        self.menuBar = MenuBarController(session: session, hotkey: hotkey)
        buildOverlay(style: SettingsStore.shared.overlayStyle, session: session)

        // Meeting transcription shares the Parakeet engine (the actor
        // serializes decodes with dictation safely). Only wired when the real
        // engine loaded.
        if let parakeet = self.transcriber {
            MeetingTranscriptionService.shared.transcriber = parakeet
        }
        self.meetingIndicator = MeetingIndicatorController(
            service: MeetingTranscriptionService.shared,
            session: session
        )

        // Read Aloud: the notch mini-player (triggers: menu bar + hotkey).
        speechOverlay = SpeechOverlayController()
        // Warm the neural voice at launch when it's the chosen voice — the
        // first CoreML load compiles for the ANE and takes seconds; doing it
        // now means the first read starts instantly.
        if SettingsStore.shared.ttsVoiceIdentifier.hasPrefix(NeuralSpeechEngine.voiceIdentifierPrefix) {
            Task { try? await NeuralSpeechEngine.shared.prepare() }
        }

        // Start Sparkle's background update-check cycle.
        _ = UpdaterService.shared

        // Pause music while recording; resume the moment recording ends
        // (processing/inserting don't need silence). Also pause the meeting
        // "You" track — dictated speech belongs to the dictation pipeline,
        // not the meeting transcript.
        session.$state
            .removeDuplicates()
            .sink { [weak self] state in
                // A latched recording that ended without the un-latch tap
                // (hands-free auto-stop, or an error) must release the latch,
                // or the next press gets swallowed as an "end" tap.
                if state != .recording, self?.toggleLocked == true {
                    self?.toggleLocked = false
                    self?.pressStartTime = nil
                    self?.lastShortReleaseTime = nil
                }
                if state == .recording {
                    // Dictation always wins the speakers and the mic:
                    // otherwise the mic transcribes the Mac talking to itself.
                    SpeechService.shared.stop()
                    MediaPauseService.shared.pausePlayingApps()
                } else if SpeechService.shared.state == .idle {
                    MediaPauseService.shared.resumePausedApps()
                }
                MeetingTranscriptionService.shared.micSuppressed = (state == .recording)
            }
            .store(in: &cancellables)

        // Free Kokoro (hundreds of MB resident) after 10 idle minutes; warm
        // reloads are sub-second, so the next read barely notices.
        SpeechService.shared.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                self.kokoroIdleTask?.cancel()
                self.kokoroIdleTask = nil
                guard state == .idle else { return }
                self.kokoroIdleTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000)
                    guard !Task.isCancelled, SpeechService.shared.state == .idle else { return }
                    NeuralSpeechEngine.shared.unload()
                }
            }
            .store(in: &cancellables)

        // Reading aloud over Spotify is as bad as dictating over it — same
        // pause/resume dance (MediaPauseService honors the settings toggle).
        // Collapse to a speaking bool first: pause/resume WITHIN one read
        // must not re-fire pausePlayingApps(), which would wipe its memory
        // of what it paused.
        SpeechService.shared.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { [weak self] speaking in
                if speaking {
                    MediaPauseService.shared.pausePlayingApps()
                } else if self?.session?.state == .idle {
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
        hotkey.configureReadAloud(binding: SettingsStore.shared.readAloudBinding)
        hotkey.events
            .sink { [weak self] event in self?.handle(event: event, session: session) }
            .store(in: &cancellables)
        hotkey.readAloudEvents
            .sink { [weak self] in
                // Only when dictation is quiet — mid-recording the same
                // physical gesture is a chord, not a read-aloud request.
                guard self?.session?.state == .idle else { return }
                ReadAloudController.shared.toggle()
            }
            .store(in: &cancellables)
        SettingsStore.shared.$readAloudBinding
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] binding in
                self?.hotkey.configureReadAloud(binding: binding)
            }
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
                // Re-push the read-aloud key from settings: a conflict with
                // the OLD dictation key may have suppressed it, and the new
                // dictation key may free it up (or newly collide).
                self.hotkey.configureReadAloud(binding: SettingsStore.shared.readAloudBinding)
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
        let polish: any PolishStage
        switch SettingsStore.shared.polishEngine {
        case .off:
            polish = NullPolishStage()
        case .s1Mini:
            polish = S1PolishStage.shared
        }
        return FormattingPipeline(
            rule: RuleStage(customReplacements: vocabulary),
            polish: polish
        )
    }

    /// Keeps the resident model in sync with the engine setting: loading it
    /// when s1-mini is selected, freeing ~500 MB when polish is turned off.
    private static func applyPolishEngineChange() {
        switch SettingsStore.shared.polishEngine {
        case .s1Mini:
            S1ModelStore.shared.ensureDownloaded()
            if S1ModelStore.isModelPresent {
                Task { await S1PolishStage.shared.prepare() }
            }
        case .off:
            Task { await S1PolishStage.shared.unload() }
        }
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
                if SettingsStore.shared.handsFreeAutoStop {
                    session.armAutoStop()
                }
                return
            }
            // Single short tap — discard the negligible audio so Parakeet
            // doesn't error on an empty buffer. Wait for a possible second tap.
            lastShortReleaseTime = now
            Task { await session.cancelRecording() }
        }
    }
}
