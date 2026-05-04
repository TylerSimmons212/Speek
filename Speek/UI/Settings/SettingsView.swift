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
