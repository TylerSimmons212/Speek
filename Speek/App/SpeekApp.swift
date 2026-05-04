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

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyManager()
    private let audio = AudioCaptureService()
    private var cancellables = Set<AnyCancellable>()
    private var captureTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotkey.events
            .sink { [weak self] event in self?.handle(event: event) }
            .store(in: &cancellables)
        hotkey.start()
    }

    private func handle(event: HotkeyManager.Event) {
        switch event {
        case .pressed:
            captureTask = Task { [audio] in
                do {
                    let stream = try await audio.start()
                    var total = 0
                    for await chunk in stream { total += chunk.count }
                    print("Total samples: \(total)")
                } catch {
                    print("audio error: \(error)")
                }
            }
        case .released:
            Task { [audio] in await audio.stop() }
        }
    }
}
