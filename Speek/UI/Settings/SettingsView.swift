import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case general, readAloud, permissions, audio, formatting, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .readAloud: return "Read Aloud"
        case .permissions: return "Permissions"
        case .audio: return "Audio"
        case .formatting: return "Formatting"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .readAloud: return "speaker.wave.2"
        case .permissions: return "lock.shield"
        case .audio: return "mic"
        case .formatting: return "text.alignleft"
        case .about: return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var perms = PermissionsCoordinator.shared
    @State private var refreshTimer: Timer?
    @State private var selection: SettingsCategory? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                NavigationLink(value: category) {
                    Label(category.title, systemImage: category.systemImage)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
            .navigationTitle("Speek")
        } detail: {
            Group {
                switch selection ?? .general {
                case .general: GeneralPane()
                case .readAloud: ReadAloudPane()
                case .permissions: PermissionsPane()
                case .audio: AudioPane()
                case .formatting: FormattingPane()
                case .about: AboutPane()
                }
            }
            .navigationTitle((selection ?? .general).title)
            .navigationSplitViewColumnWidth(min: 460, ideal: 500)
        }
        .frame(minWidth: 700, minHeight: 480, idealHeight: 520)
        .onAppear {
            perms.refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in perms.refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("Activation") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dictation key").font(.body.weight(.medium))
                    HotkeyRecorderView(binding: $settings.hotkeyBinding)
                    Text("Pick a preset or record your own — any modifier key or F13–F20 works. Hold to talk, or double-tap to latch on; tap once more to end a latched session.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                Toggle(isOn: $settings.handsFreeAutoStop) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hands-free stop").font(.body.weight(.medium))
                        Text("A latched (double-tap) session ends on its own after you stop talking for a moment. Held push-to-talk is never auto-stopped.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Overlay") {
                Picker("Style", selection: $settings.overlayStyle) {
                    Text("Notch (Dynamic Island)").tag(SettingsStore.OverlayStyle.notch)
                    Text("Bottom pill").tag(SettingsStore.OverlayStyle.bottomPill)
                }
                Text("Notch style expands out of the MacBook notch. Screens without one get a mini virtual notch that appears only while Speek is active.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("Show live transcript while dictating", isOn: $settings.livePreviewEnabled)
                Text("Words appear in the overlay as you speak. Turning this off saves a little battery on long dictations.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Read Aloud

private struct ReadAloudPane: View {
    @ObservedObject var settings = SettingsStore.shared
    @ObservedObject var speech = SpeechService.shared
    @State private var neuralDownloading = false
    @State private var neuralMessage: String?

    private static let previewText = "Hi! This is how I'll sound when Speek reads to you."

    var body: some View {
        Form {
            if !settings.kokoroVoiceDownloaded {
                Section("Neural voice") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Speek reads with Kokoro, an open-source neural voice that runs entirely on this Mac's Neural Engine — dramatically more natural than the system voices. One-time download, then fully offline.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 10) {
                            Button(neuralDownloading ? "Downloading…" : "Download neural voice (~170 MB)") {
                                downloadNeuralVoice()
                            }
                            .disabled(neuralDownloading)
                            if neuralDownloading {
                                ProgressView().controlSize(.small)
                            }
                            if let neuralMessage {
                                Text(neuralMessage)
                                    .font(.callout)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Text("Until it's downloaded, reading uses a basic system voice.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Voice") {
                Picker("Voice", selection: voiceSelection) {
                    ForEach(KokoroVoiceCatalog.voices) { voice in
                        Text("\(voice.name)  —  \(voice.flavor)").tag(voice.id)
                    }
                }
                .disabled(!settings.kokoroVoiceDownloaded)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Text("Speed")
                        Text("Slower").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.ttsRate, in: 0.35...0.65)
                        Text("Faster").font(.caption).foregroundStyle(.secondary)
                    }
                    Button(speech.isSpeaking ? "Stop preview" : "Preview voice") {
                        if speech.isSpeaking {
                            speech.stop()
                        } else {
                            speech.speak(Self.previewText)
                        }
                    }
                    Text("New voices download automatically the first time you use them (about half a megabyte each). Everything runs on-device.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            }
            Section("Trigger") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Select text anywhere, then use the menu bar item (Read Selected Text Aloud) or the keyboard shortcut below. Tap the shortcut to read the selection; tap again to stop.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if settings.readAloudBinding != nil {
                        HotkeyRecorderView(binding: Binding(
                            get: { settings.readAloudBinding ?? .rightOption },
                            set: { settings.readAloudBinding = $0 }
                        ))
                        if settings.readAloudBinding == settings.hotkeyBinding {
                            Text("That's your dictation key — read aloud won't trigger until you pick a different one.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button("Remove shortcut") { settings.readAloudBinding = nil }
                            .controlSize(.small)
                    } else {
                        Button("Add keyboard shortcut…") {
                            settings.readAloudBinding = Self.defaultBinding(avoiding: settings.hotkeyBinding)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// The picker always shows a valid neural voice: legacy Apple ids (or
    /// empty "automatic") display as the default voice, and selecting any
    /// entry writes a neural id back.
    private var voiceSelection: Binding<String> {
        Binding(
            get: {
                KokoroVoiceCatalog.voice(forIdentifier: settings.ttsVoiceIdentifier)?.id
                    ?? NeuralSpeechEngine.defaultVoiceIdentifier
            },
            set: { settings.ttsVoiceIdentifier = $0 }
        )
    }

    private func downloadNeuralVoice() {
        neuralDownloading = true
        neuralMessage = nil
        Task { @MainActor in
            do {
                try await NeuralSpeechEngine.shared.prepare()
                settings.kokoroVoiceDownloaded = true
                settings.ttsVoiceIdentifier = NeuralSpeechEngine.defaultVoiceIdentifier
            } catch {
                neuralMessage = "Download failed — check your connection and try again. (\(error.localizedDescription))"
            }
            neuralDownloading = false
        }
    }

    private static func defaultBinding(avoiding dictation: HotkeyBinding) -> HotkeyBinding {
        [.rightOption, .rightCommand, .fn].first { $0 != dictation } ?? .rightOption
    }
}

// MARK: - Permissions

private struct PermissionsPane: View {
    @ObservedObject var perms = PermissionsCoordinator.shared

    var body: some View {
        Form {
            Section {
                PermissionRow(
                    title: "Microphone",
                    icon: "mic.fill",
                    granted: perms.hasMic,
                    detail: "Required to capture audio for transcription.",
                    action: {
                        Task { await perms.requestMic() }
                        perms.openSystemSettings(.microphone)
                    }
                )
                PermissionRow(
                    title: "Accessibility",
                    icon: "accessibility",
                    granted: perms.hasAccessibility,
                    detail: "Required to insert transcribed text into the focused app.",
                    action: {
                        perms.requestAccessibility()
                        perms.openSystemSettings(.accessibility)
                    }
                )
                PermissionRow(
                    title: "Input Monitoring",
                    icon: "keyboard",
                    granted: perms.hasInputMonitoring,
                    detail: "Required for the global push-to-talk hotkey to work across apps.",
                    action: {
                        perms.requestInputMonitoring()
                        perms.openSystemSettings(.inputMonitoring)
                    }
                )
            }
            if !perms.hasAccessibility || !perms.hasInputMonitoring {
                Section("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If a stale Speek entry already exists in System Settings → Privacy & Security, remove it and drag this build in.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                        } label: {
                            Label("Reveal Speek.app in Finder", systemImage: "magnifyingglass")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

private struct PermissionRow: View {
    let title: String
    let icon: String
    let granted: Bool
    let detail: String
    let action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(granted ? .secondary : .primary)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    statusBadge
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action, !granted {
                Button("Open Settings", action: action)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(granted ? "Granted" : "Needed")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(granted ? .green : .orange)
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        Form {
            Section("While dictating") {
                Toggle(isOn: $settings.pauseMediaWhileDictating) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pause music while dictating").font(.body.weight(.medium))
                        Text("Pauses Music or Spotify when you start talking and resumes when you finish. macOS will ask once for permission to control each player.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Meeting transcription") {
                Toggle(isOn: $settings.meetingEchoCancellation) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text("Echo cancellation").font(.body.weight(.medium))
                            Text("Beta")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                        Text("For calls without headphones: removes the other side's voice that your mic picks up from the speakers, so it isn't transcribed twice as \u{201C}You.\u{201D} Downloads a 19 MB model on first use. Applies from the next meeting.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Microphone") {
                Picker("Input device", selection: $settings.micDeviceID) {
                    Text("System default").tag("default")
                }
                LabeledContent("Note") {
                    Text("Speek currently uses the macOS default input. Per-device selection is coming.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 280, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - Formatting

private struct FormattingPane: View {
    @ObservedObject var settings = SettingsStore.shared
    @State private var newKey = ""
    @State private var newValue = ""

    var body: some View {
        Form {
            Section("AI polish") {
                Picker("Engine", selection: $settings.polishEngine) {
                    Text("Off").tag(SettingsStore.PolishEngine.off)
                    Text("S1-mini (on-device)").tag(SettingsStore.PolishEngine.s1Mini)
                }
                Text("S1-mini by Superwhisper — a small on-device model built for dictation cleanup: removes fillers, resolves self-corrections, fixes punctuation, and writes out spoken numbers and dates. Nothing leaves your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.polishEngine == .s1Mini {
                    S1ModelRow()
                }
            }
            Section("Insertion") {
                Toggle(isOn: $settings.axInsertionEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Accessibility insertion").font(.body.weight(.medium))
                        Text("Types text directly into the focused field. Falls back to clipboard-paste if AX is denied.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                InsertionOverridesView()
            }
            Section("Learning") {
                Toggle(isOn: $settings.learnFromCorrections) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Learn from corrections").font(.body.weight(.medium))
                        Text("When you fix a single word in text Speek just inserted, it's added to your vocabulary so the same word transcribes correctly next time. Speek waits until you stop editing before committing.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Section("Custom vocabulary") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Replace spoken words with the spelling you want. Speek also listens for these terms, so close mishearings get fixed too. Match is case-insensitive; the replacement is used verbatim.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !settings.customReplacements.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(settings.customReplacements.keys.sorted(), id: \.self) { key in
                                HStack {
                                    Text(key).frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                                    Text(settings.customReplacements[key] ?? "").frame(maxWidth: .infinity, alignment: .leading)
                                    Button {
                                        var dict = settings.customReplacements
                                        dict.removeValue(forKey: key)
                                        settings.customReplacements = dict
                                    } label: {
                                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                                Divider()
                            }
                        }
                    }
                    HStack {
                        TextField("Spoken", text: $newKey)
                        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary)
                        TextField("Replacement", text: $newValue)
                        Button {
                            let trimmedKey = newKey.trimmingCharacters(in: .whitespaces)
                            let trimmedVal = newValue.trimmingCharacters(in: .whitespaces)
                            guard !trimmedKey.isEmpty, !trimmedVal.isEmpty else { return }
                            var dict = settings.customReplacements
                            dict[trimmedKey] = trimmedVal
                            settings.customReplacements = dict
                            newKey = ""
                            newValue = ""
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newValue.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 84, height: 84)
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text("Speek").font(.system(size: 28, weight: .semibold, design: .rounded))
                Text("Voice dictation, locally on your Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 2) {
                Text("Version \(appVersion) (\(buildNumber))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Powered by Parakeet ASR & Apple Foundation Models")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }
}

/// Download status row for the s1-mini weights (~484 MB, one-time).
private struct S1ModelRow: View {
    @ObservedObject var store = S1ModelStore.shared

    var body: some View {
        HStack(spacing: 10) {
            switch store.state {
            case .notDownloaded:
                Button("Download model (484 MB)") {
                    store.ensureDownloaded()
                }
                Text("One-time download; cached locally after that.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .downloading(let progress):
                ProgressView(value: progress)
                    .frame(maxWidth: 180)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Model ready")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Retry") { store.retry() }
            }
        }
    }
}

/// Per-app insertion overrides: apps whose text fields misbehave with AX
/// writes (many Electron apps) can be pinned to paste (⌘V with clipboard
/// restore) or raw keystrokes.
private struct InsertionOverridesView: View {
    @ObservedObject var settings = SettingsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-app method").font(.body.weight(.medium))
            Text("Most apps work best with the default. If text lands garbled or not at all in a specific app, pin it to Paste.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(settings.insertionOverrides.keys.sorted(), id: \.self) { bundleID in
                HStack(spacing: 8) {
                    Text(Self.displayName(for: bundleID))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Picker("", selection: Binding(
                        get: { settings.insertionOverrides[bundleID] ?? SettingsStore.InsertionMethod.paste.rawValue },
                        set: { settings.insertionOverrides[bundleID] = $0 }
                    )) {
                        Text("Paste (⌘V)").tag(SettingsStore.InsertionMethod.paste.rawValue)
                        Text("Type keystrokes").tag(SettingsStore.InsertionMethod.type.rawValue)
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    Button {
                        settings.insertionOverrides.removeValue(forKey: bundleID)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove override")
                }
            }
            Button("Add App…") { addApp() }
        }
        .padding(.vertical, 4)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app whose insertion method to override"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        settings.insertionOverrides[bundleID] = SettingsStore.InsertionMethod.paste.rawValue
    }

    private static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return bundleID
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}
