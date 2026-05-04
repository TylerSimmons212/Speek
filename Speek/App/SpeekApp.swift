import SwiftUI
import AppKit
import Combine

@main
struct SpeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyManager()
    private let audio = AudioCaptureService()
    private var transcriber: ParakeetEngine?
    private var session: DictationSession?
    private var menuBar: MenuBarController?
    private var cancellables = Set<AnyCancellable>()

    nonisolated func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            NSApp.setActivationPolicy(.accessory)
            await self.setUp()
        }
    }

    @MainActor
    private func setUp() async {
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

        let pipeline = FormattingPipeline(rule: RuleStage(), polish: FMPolishStage())
        let session = DictationSession(
            audio: audio,
            transcriber: transcriber,
            pipeline: pipeline,
            injector: CompositeInjector()
        )
        self.session = session
        self.menuBar = MenuBarController(session: session)

        hotkey.events
            .sink { [weak self] event in self?.handle(event: event, session: session) }
            .store(in: &cancellables)
        hotkey.start()
    }

    private func handle(event: HotkeyManager.Event, session: DictationSession) {
        switch event {
        case .pressed:
            session.startRecording()
        case .released:
            Task { await session.stopRecording() }
        }
    }
}
