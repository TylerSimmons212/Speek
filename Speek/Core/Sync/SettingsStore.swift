import Foundation
import Combine
import ServiceManagement

@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum HotkeyMode: String { case pushToTalk, toggle }
    enum OverlayStyle: String { case notch, bottomPill }
    enum PolishEngine: String { case off, s1Mini }
    /// Per-app insertion override values (absence of an override = the
    /// default AX-first ladder).
    enum InsertionMethod: String { case paste, type }

    /// The dictation trigger key. Persisted as JSON; the legacy three-option
    /// string ("hotkey" key) migrates on first read.
    @Published var hotkeyBinding: HotkeyBinding {
        didSet {
            if let json = hotkeyBinding.jsonString {
                sync.setString(json, forKey: "hotkeyBinding")
            }
        }
    }
    @Published var hotkeyMode: HotkeyMode {
        didSet { sync.setString(hotkeyMode.rawValue, forKey: "hotkeyMode") }
    }
    @Published var micDeviceID: String {
        didSet { sync.setString(micDeviceID, forKey: "micDeviceID") }
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
    /// Whether s1-mini cleans up transcripts beyond the rule layer.
    @Published var polishEngine: PolishEngine {
        didSet { sync.setString(polishEngine.rawValue, forKey: "polishEngine") }
    }
    @Published var learnFromCorrections: Bool {
        didSet { sync.setBool(learnFromCorrections, forKey: "learnFromCorrections") }
    }
    /// Hands-free: a latched (double-tap) recording ends automatically after
    /// a trailing pause. Never applies to held push-to-talk.
    @Published var handsFreeAutoStop: Bool {
        didSet { sync.setBool(handsFreeAutoStop, forKey: "handsFreeAutoStop") }
    }
    /// bundle identifier → InsertionMethod rawValue. Apps whose AX writes
    /// misbehave (Electron) can be pinned to paste or keystrokes.
    @Published var insertionOverrides: [String: String] {
        didSet { sync.setStringDictionary(insertionOverrides, forKey: "insertionOverrides") }
    }
    /// Pause Music/Spotify while recording; resume after. On by default.
    @Published var pauseMediaWhileDictating: Bool {
        didSet { sync.setBool(pauseMediaWhileDictating, forKey: "pauseMedia") }
    }
    /// First-run onboarding has been completed (or skipped).
    @Published var onboardingCompleted: Bool {
        didSet { sync.setBool(onboardingCompleted, forKey: "onboardingCompleted") }
    }
    /// The user has seen the meeting-transcription consent note.
    @Published var meetingConsentAcknowledged: Bool {
        didSet { sync.setBool(meetingConsentAcknowledged, forKey: "meetingConsent") }
    }
    /// Beta: LocalVQE echo cancellation on the meeting mic track, using the
    /// system-audio tap as the far-end reference. Off by default; read at
    /// meeting start.
    @Published var meetingEchoCancellation: Bool {
        didSet { sync.setBool(meetingEchoCancellation, forKey: "meetingEchoCancellation") }
    }
    /// Optional read-aloud trigger key (tap to read the selection, tap again
    /// to stop). Nil = no hotkey; the Service and menu bar still work.
    @Published var readAloudBinding: HotkeyBinding? {
        didSet { sync.setString(readAloudBinding?.jsonString ?? "", forKey: "readAloudBinding") }
    }
    /// Text-to-speech voice identifier. Empty = automatic (best installed
    /// Premium/Enhanced voice for the user's language).
    @Published var ttsVoiceIdentifier: String {
        didSet { sync.setString(ttsVoiceIdentifier, forKey: "ttsVoice") }
    }
    /// AVSpeechUtterance rate, 0–1 (0.5 = the system's natural pace).
    @Published var ttsRate: Double {
        didSet { sync.setDouble(ttsRate, forKey: "ttsRate") }
    }
    /// The Kokoro neural voice has been downloaded (shows in the picker).
    /// If the cache is ever wiped, first playback transparently re-downloads.
    @Published var kokoroVoiceDownloaded: Bool {
        didSet { sync.setBool(kokoroVoiceDownloaded, forKey: "kokoroDownloaded") }
    }

    private let sync: SyncStore
    init(sync: SyncStore = SyncStore()) {
        self.sync = sync
        if let json = sync.string(forKey: "hotkeyBinding"),
           let binding = HotkeyBinding.from(jsonString: json) {
            self.hotkeyBinding = binding
        } else if let legacy = sync.string(forKey: "hotkey"),
                  let migrated = HotkeyBinding.fromLegacyChoice(legacy) {
            self.hotkeyBinding = migrated
        } else {
            self.hotkeyBinding = .fn
        }
        self.hotkeyMode = HotkeyMode(rawValue: sync.string(forKey: "hotkeyMode") ?? "pushToTalk") ?? .pushToTalk
        self.micDeviceID = sync.string(forKey: "micDeviceID") ?? "default"
        self.axInsertionEnabled = sync.bool(forKey: "axEnabled")
        // Default ON: the preview is the product's best feedback loop.
        self.livePreviewEnabled = sync.hasValue(forKey: "livePreview")
            ? sync.bool(forKey: "livePreview")
            : true
        self.overlayStyle = OverlayStyle(rawValue: sync.string(forKey: "overlayStyle") ?? "notch") ?? .notch
        self.launchAtLogin = sync.bool(forKey: "launchAtLogin")
        self.customReplacements = sync.stringDictionary(forKey: "customReplacements")
        // s1-mini is the default. Migration: an explicit "off" is respected;
        // every legacy engine value (appleIntelligence, customLLM) moves to
        // s1-mini, which replaced both.
        self.polishEngine = sync.string(forKey: "polishEngine") == "off" ? .off : .s1Mini
        // Default ON: opt-out, since the diff filter is conservative.
        self.learnFromCorrections = sync.hasValue(forKey: "learnFromCorrections")
            ? sync.bool(forKey: "learnFromCorrections")
            : true
        self.handsFreeAutoStop = sync.bool(forKey: "handsFreeAutoStop")
        self.insertionOverrides = sync.stringDictionary(forKey: "insertionOverrides")
        self.pauseMediaWhileDictating = sync.hasValue(forKey: "pauseMedia")
            ? sync.bool(forKey: "pauseMedia")
            : true
        self.onboardingCompleted = sync.bool(forKey: "onboardingCompleted")
        self.meetingConsentAcknowledged = sync.bool(forKey: "meetingConsent")
        self.meetingEchoCancellation = sync.bool(forKey: "meetingEchoCancellation")
        if let json = sync.string(forKey: "readAloudBinding"), !json.isEmpty,
           let binding = HotkeyBinding.from(jsonString: json) {
            self.readAloudBinding = binding
        } else {
            self.readAloudBinding = nil
        }
        self.ttsVoiceIdentifier = sync.string(forKey: "ttsVoice") ?? ""
        self.ttsRate = sync.hasValue(forKey: "ttsRate") ? sync.double(forKey: "ttsRate") : 0.5
        self.kokoroVoiceDownloaded = sync.bool(forKey: "kokoroDownloaded")
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
