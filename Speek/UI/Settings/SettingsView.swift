import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Push-to-talk key", selection: $settings.hotkeyChoice) {
                    Text("Fn").tag(SettingsStore.HotkeyChoice.fn)
                    Text("Right Option").tag(SettingsStore.HotkeyChoice.rightOption)
                    Text("Right Command").tag(SettingsStore.HotkeyChoice.rightCommand)
                }
            }
            Section("Microphone") {
                Picker("Input device", selection: $settings.micDeviceID) {
                    Text("System default").tag("default")
                }
            }
            Section("Formatting") {
                Toggle("Use Apple Foundation Models", isOn: $settings.foundationModelsEnabled)
                Toggle("Use Accessibility insertion", isOn: $settings.axInsertionEnabled)
            }
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .padding()
        .frame(width: 460, height: 360)
    }
}

// Temporary stub — Task 5.1 replaces this with a real SyncStore-backed store and moves it to a separate file.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum HotkeyChoice: String { case fn, rightOption, rightCommand }
    @Published var hotkeyChoice: HotkeyChoice = .fn
    @Published var micDeviceID: String = "default"
    @Published var foundationModelsEnabled: Bool = true
    @Published var axInsertionEnabled: Bool = true
    @Published var launchAtLogin: Bool = false
}
