import Foundation
import Combine
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum HotkeyChoice: String { case fn, rightOption, rightCommand }
    enum HotkeyMode: String { case pushToTalk, toggle }
    enum OverlayStyle: String { case notch, bottomPill }
    enum PolishEngine: String { case off, appleIntelligence, customLLM }
    enum PolishMode: String { case whenNeeded, always }

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
    /// Rolling transcript in the overlay while recording. On by default.
    @Published var livePreviewEnabled: Bool {
        didSet { sync.setBool(livePreviewEnabled, forKey: "livePreview") }
    }
    /// Where the dictation UI lives: expanding out of the notch (Dynamic
    /// Island-style) or the classic pill at the bottom of the screen.
    @Published var overlayStyle: OverlayStyle {
        didSet { sync.setString(overlayStyle.rawValue, forKey: "overlayStyle") }
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
    /// Which LLM cleans up transcripts beyond the regex layer.
    @Published var polishEngine: PolishEngine {
        didSet { sync.setString(polishEngine.rawValue, forKey: "polishEngine") }
    }
    /// Run polish on every dictation, or only when the regex layer flags an
    /// ambiguous self-correction it couldn't resolve.
    @Published var polishMode: PolishMode {
        didSet { sync.setString(polishMode.rawValue, forKey: "polishMode") }
    }
    /// OpenAI-compatible base URL (Ollama default). Used when engine = customLLM.
    @Published var llmEndpoint: String {
        didSet { sync.setString(llmEndpoint, forKey: "llmEndpoint") }
    }
    @Published var llmModel: String {
        didSet { sync.setString(llmModel, forKey: "llmModel") }
    }
    /// Stored in the keychain, never in UserDefaults. Empty = no key (fine
    /// for local endpoints).
    @Published var llmAPIKey: String {
        didSet { KeychainService.setString(llmAPIKey, forKey: "llmAPIKey") }
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
        // Default ON: the preview is the product's best feedback loop.
        self.livePreviewEnabled = sync.hasValue(forKey: "livePreview")
            ? sync.bool(forKey: "livePreview")
            : true
        self.overlayStyle = OverlayStyle(rawValue: sync.string(forKey: "overlayStyle") ?? "notch") ?? .notch
        self.launchAtLogin = sync.bool(forKey: "launchAtLogin")
        self.customReplacements = sync.stringDictionary(forKey: "customReplacements")
        // Migration: users who had the old Apple FM toggle on keep that engine.
        if let raw = sync.string(forKey: "polishEngine"), let engine = PolishEngine(rawValue: raw) {
            self.polishEngine = engine
        } else {
            self.polishEngine = sync.bool(forKey: "fmEnabled") ? .appleIntelligence : .off
        }
        self.polishMode = PolishMode(rawValue: sync.string(forKey: "polishMode") ?? "whenNeeded") ?? .whenNeeded
        self.llmEndpoint = sync.string(forKey: "llmEndpoint") ?? "http://localhost:11434/v1"
        self.llmModel = sync.string(forKey: "llmModel") ?? "llama3.2"
        self.llmAPIKey = KeychainService.string(forKey: "llmAPIKey") ?? ""
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
