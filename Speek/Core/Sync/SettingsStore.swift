import Foundation
import Combine

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum HotkeyChoice: String { case fn, rightOption, rightCommand }

    @Published var hotkeyChoice: HotkeyChoice {
        didSet { sync.setString(hotkeyChoice.rawValue, forKey: "hotkey") }
    }
    @Published var micDeviceID: String {
        didSet { sync.setString(micDeviceID, forKey: "micDeviceID") }
    }
    @Published var foundationModelsEnabled: Bool {
        didSet { sync.setBool(foundationModelsEnabled, forKey: "fmEnabled") }
    }
    @Published var axInsertionEnabled: Bool {
        didSet { sync.setBool(axInsertionEnabled, forKey: "axEnabled") }
    }
    @Published var launchAtLogin: Bool {
        didSet { sync.setBool(launchAtLogin, forKey: "launchAtLogin") }
    }

    private let sync: SyncStore
    init(sync: SyncStore = SyncStore()) {
        self.sync = sync
        self.hotkeyChoice = HotkeyChoice(rawValue: sync.string(forKey: "hotkey") ?? "fn") ?? .fn
        self.micDeviceID = sync.string(forKey: "micDeviceID") ?? "default"
        self.foundationModelsEnabled = sync.bool(forKey: "fmEnabled")
        self.axInsertionEnabled = sync.bool(forKey: "axEnabled")
        self.launchAtLogin = sync.bool(forKey: "launchAtLogin")
    }
}
