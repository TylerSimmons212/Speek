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
    private var cancellables = Set<AnyCancellable>()
    private var captureTask: Task<Void, Never>?
    private var collectedSamples: [Float] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                self.transcriber = try await ParakeetEngine()
                print("Parakeet ready")
            } catch {
                print("Parakeet load failed: \(error)")
            }
        }
        hotkey.events
            .sink { [weak self] event in self?.handle(event: event) }
            .store(in: &cancellables)
        hotkey.start()
    }

    private func handle(event: HotkeyManager.Event) {
        switch event {
        case .pressed:
            collectedSamples = []
            let audio = self.audio
            captureTask = Task { @MainActor [weak self] in
                do {
                    let stream = try await audio.start()
                    for await chunk in stream {
                        self?.collectedSamples.append(contentsOf: chunk)
                    }
                } catch {
                    print("audio error: \(error)")
                }
            }
        case .released:
            let audio = self.audio
            let transcriber = self.transcriber
            let samples = collectedSamples
            Task {
                await audio.stop()
                guard let transcriber else { return }
                do {
                    let text = try await transcriber.transcribe(samples: samples)
                    print("Transcript: \(text)")
                } catch {
                    print("transcribe error: \(error)")
                }
            }
        }
    }
}
