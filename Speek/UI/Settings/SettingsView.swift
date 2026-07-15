import SwiftUI
import AppKit

enum SettingsCategory: String, Hashable, CaseIterable, Identifiable {
    case general, permissions, audio, formatting, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .permissions: return "Permissions"
        case .audio: return "Audio"
        case .formatting: return "Formatting"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
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
                PermissionRow(
                    title: "Apple Foundation Models",
                    icon: "sparkles",
                    granted: perms.hasFoundationModels,
                    detail: "Optional. Enable Apple Intelligence in System Settings to use the LLM polish stage.",
                    action: nil
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
    @State private var probeResult: String?
    @State private var probing = false

    var body: some View {
        Form {
            Section("AI polish") {
                Picker("Engine", selection: $settings.polishEngine) {
                    Text("Off").tag(SettingsStore.PolishEngine.off)
                    Text("Apple Intelligence").tag(SettingsStore.PolishEngine.appleIntelligence)
                    Text("Custom (OpenAI-compatible)").tag(SettingsStore.PolishEngine.customLLM)
                }
                Text("Cleans up what the regex layer can't: subtle self-corrections, grammar, spoken numbers. Custom works with Ollama or LM Studio running locally — free and private — or any cloud provider.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.polishEngine != .off {
                    Picker("Run", selection: $settings.polishMode) {
                        Text("Only when needed").tag(SettingsStore.PolishMode.whenNeeded)
                        Text("On every dictation").tag(SettingsStore.PolishMode.always)
                    }
                }
                if settings.polishEngine == .customLLM {
                    TextField("Endpoint", text: $settings.llmEndpoint, prompt: Text("http://localhost:11434/v1"))
                        .autocorrectionDisabled()
                    TextField("Model", text: $settings.llmModel, prompt: Text("llama3.2"))
                        .autocorrectionDisabled()
                    SecureField("API key (not needed for local endpoints)", text: $settings.llmAPIKey)
                    HStack(spacing: 10) {
                        Button(probing ? "Testing…" : "Test connection") {
                            probing = true
                            probeResult = nil
                            let config = LLMPolishStage.Config(
                                endpoint: settings.llmEndpoint,
                                model: settings.llmModel,
                                apiKey: settings.llmAPIKey
                            )
                            Task {
                                let outcome = await LLMPolishStage.probe(config: config)
                                await MainActor.run {
                                    probeResult = outcome
                                    probing = false
                                }
                            }
                        }
                        .disabled(probing)
                        if let probeResult {
                            Text(probeResult)
                                .font(.callout)
                                .foregroundStyle(probeResult.hasPrefix("Connected") ? .green : .orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
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
                    Text("Replace spoken words with the spelling you want. Match is case-insensitive; the replacement is used verbatim.")
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
