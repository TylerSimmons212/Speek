import Foundation
import Combine
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum HotkeyChoice: String { case fn, rightOption, rightCommand }
    enum HotkeyMode: String { case pushToTalk, toggle }

    @Published var hotkeyChoice: HotkeyChoice {
        didSet { sync.setString(hotkeyChoice.rawValue, forKey: "hotkey") }
    }
    @Published var hotkeyMode: HotkeyMode {
        didSet { sync.setString(hotkeyMode.rawValue, forKey: "hotkeyMode") }
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
        didSet {
            sync.setBool(launchAtLogin, forKey: "launchAtLogin")
            applyLaunchAtLogin(launchAtLogin)
        }
    }
    @Published var customReplacements: [String: String] {
        didSet { sync.setStringDictionary(customReplacements, forKey: "customReplacements") }
    }
    @Published var learnFromCorrections: Bool {
        didSet { sync.setBool(learnFromCorrections, forKey: "learnFromCorrections") }
    }

    private let sync: SyncStore
    init(sync: SyncStore = SyncStore()) {
        self.sync = sync
        self.hotkeyChoice = HotkeyChoice(rawValue: sync.string(forKey: "hotkey") ?? "fn") ?? .fn
        self.hotkeyMode = HotkeyMode(rawValue: sync.string(forKey: "hotkeyMode") ?? "pushToTalk") ?? .pushToTalk
        self.micDeviceID = sync.string(forKey: "micDeviceID") ?? "default"
        self.foundationModelsEnabled = sync.bool(forKey: "fmEnabled")
        self.axInsertionEnabled = sync.bool(forKey: "axEnabled")
        self.launchAtLogin = sync.bool(forKey: "launchAtLogin")
        self.customReplacements = sync.stringDictionary(forKey: "customReplacements")
        // Default ON: opt-out, since the diff filter is conservative.
        self.learnFromCorrections = sync.hasValue(forKey: "learnFromCorrections")
            ? sync.bool(forKey: "learnFromCorrections")
            : true
    }
}

extension SettingsStore {
    func applyLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
