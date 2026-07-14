import SwiftUI
import AppKit

/// First-run wizard: welcome → permissions → try it → done.
/// The tryout step is gated on one real dictation landing in the playground —
/// the single best predictor that a user actually "got it".
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, tryout, done
    }

    @ObservedObject var session: DictationSession
    @ObservedObject private var perms = PermissionsCoordinator.shared
    @ObservedObject private var settings = SettingsStore.shared
    /// Fired when the user clears the permissions step — the app starts the
    /// hotkey event tap here (creating it earlier would itself trigger the
    /// Input Monitoring prompt before the user asked for it).
    let onPermissionsGranted: () -> Void
    /// Attempts the event-tap creation. This — not IOHIDRequestAccess — is
    /// what reliably registers the app in the Input Monitoring list in
    /// System Settings, so the Grant button triggers it deliberately.
    let onRequestInputMonitoring: () -> Void
    /// Brings the onboarding window back to front — called when a permission
    /// flips to granted so the user lands back in the flow instead of being
    /// stranded in System Settings or behind a dismissed dialog.
    let onRefocus: () -> Void
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var playgroundText = ""
    @State private var tryoutSucceeded = false
    /// When each row's prompt was first requested. Drives second-click
    /// behavior (deep-link to System Settings) and the stuck-state hints.
    @State private var requestedAt: [String: Date] = [:]
    @State private var now = Date()

    private let refreshTick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    /// How long after a Grant click before we surface "still not detected"
    /// recovery guidance under the row.
    private let stuckHintDelay: TimeInterval = 8

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            Divider()
            footer
                .padding(16)
        }
        .frame(width: 620, height: 520)
        .onAppear { perms.refresh() }
        .onReceive(refreshTick) { date in
            now = date
            perms.refresh()
        }
        .onChange(of: session.state) { _, newState in
            // A dictation completed while the playground step is up → success.
            if step == .tryout, newState == .inserting || newState == .copied {
                tryoutSucceeded = true
            }
        }
        // Pull the user back into the flow once BOTH required permissions
        // are in — refocusing on every individual grant yanks them out of
        // System Settings while they're still mid-flow granting the next one.
        .onChange(of: requiredPermissionsGranted) { _, allGranted in
            if allGranted, step == .permissions { onRefocus() }
        }
        // Mic is the exception: its native dialog floats over our window, so
        // returning immediately after it resolves feels natural (no Settings
        // round-trip involved) — handled in the mic row's action.
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome: welcome
        case .permissions: permissions
        case .tryout: tryout
        case .done: done
        }
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 96, height: 96)
                .foregroundStyle(.tint)
            Text("Welcome to Speek")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
            Text("Talk anywhere — Speek types for you.\nEverything runs on your Mac. Your voice never leaves it.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Speek needs two permissions")
                .font(.title.weight(.semibold))
            Text("macOS will ask for these — they're what let Speek hear you and type where your cursor is.")
                .foregroundStyle(.secondary)

            OnboardingPermissionRow(
                title: "Microphone",
                icon: "mic.fill",
                granted: perms.hasMic,
                required: true,
                detail: "Captures your voice for on-device transcription.",
                hint: stuckHint(
                    key: "mic",
                    granted: perms.hasMic,
                    text: "Not detected? Open System Settings → Privacy & Security → Microphone and enable Speek."
                )
            ) {
                markRequested("mic")
                Task {
                    // The native dialog resolves the await; only fall back to
                    // System Settings if the user previously denied (the OS
                    // won't re-show the dialog then). Either way, come back.
                    await PermissionsCoordinator.shared.requestMic()
                    if PermissionsCoordinator.shared.hasMic {
                        onRefocus()
                    } else {
                        PermissionsCoordinator.shared.openSystemSettings(.microphone)
                    }
                }
            }
            OnboardingPermissionRow(
                title: "Input Monitoring",
                icon: "keyboard",
                granted: perms.hasInputMonitoring,
                required: true,
                detail: "Lets the global push-to-talk key work in any app.",
                hint: stuckHint(
                    key: "inputMonitoring",
                    granted: perms.hasInputMonitoring,
                    text: "Speek should now appear in the Input Monitoring list — toggle it on. If the list is empty, click + and add Speek from your Applications folder."
                )
            ) {
                let firstClick = markRequested("inputMonitoring")
                // Attempting the event tap is what actually registers Speek
                // in the Input Monitoring list (IOHIDRequestAccess alone
                // often doesn't) — do both, then take the user to the pane.
                PermissionsCoordinator.shared.requestInputMonitoring()
                onRequestInputMonitoring()
                if !firstClick {
                    perms.openSystemSettings(.inputMonitoring)
                }
            }
            OnboardingPermissionRow(
                title: "Accessibility",
                icon: "accessibility",
                granted: perms.hasAccessibility,
                required: false,
                detail: "Recommended — inserts text directly at your cursor and enables seamless sentence continuation.",
                hint: stuckHint(
                    key: "accessibility",
                    granted: perms.hasAccessibility,
                    text: "Toggle already on in System Settings but not detected here? That entry is stale — select Speek there, remove it with the − button, then click + and re-add Speek from Applications. (Happens after app updates.)"
                )
            ) {
                // The AX prompt has its own "Open System Settings" button, so
                // never double-open; second click deep-links directly.
                if markRequested("accessibility") {
                    PermissionsCoordinator.shared.requestAccessibility()
                } else {
                    perms.openSystemSettings(.accessibility)
                }
            }
            Spacer()
        }
    }

    /// Records the first request time for a row; returns true on first click.
    @discardableResult
    private func markRequested(_ key: String) -> Bool {
        if requestedAt[key] == nil {
            requestedAt[key] = Date()
            return true
        }
        return false
    }

    /// Recovery guidance shown under a row once a Grant click has gone
    /// unanswered for a while — the situations where macOS leaves the user
    /// with an empty list or a stale toggle and zero instructions.
    private func stuckHint(key: String, granted: Bool, text: String) -> String? {
        guard !granted, let t = requestedAt[key],
              now.timeIntervalSince(t) > stuckHintDelay else { return nil }
        return text
    }

    private var tryout: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Try it")
                .font(.title.weight(.semibold))
            HStack(spacing: 10) {
                Text("Click into the box, hold")
                    .foregroundStyle(.secondary)
                Text("Fn")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary))
                Text("and say something like “this is my first dictation”")
                    .foregroundStyle(.secondary)
            }
            TextEditor(text: $playgroundText)
                .font(.title3)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
                .frame(minHeight: 160)
            if tryoutSucceeded {
                Label("That's it — you've dictated with Speek.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.body.weight(.medium))
            } else {
                Text("Waiting for your first dictation…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .resizable()
                .frame(width: 84, height: 84)
                .foregroundStyle(.green)
            Text("You're all set")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            VStack(spacing: 6) {
                Text("Speek lives in your menu bar — look for the mic icon.")
                Text("Hold **Fn** to dictate. Double-tap it to keep recording hands-free.")
                Text("Settings → Formatting lets you pick an AI polish engine.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            Spacer()
        }
    }

    // MARK: - Footer

    private var requiredPermissionsGranted: Bool { perms.hasMic && perms.hasInputMonitoring }

    private var footer: some View {
        HStack {
            if step != .welcome, step != .done {
                Button("Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
            }
            Spacer()
            if step == .tryout, !tryoutSucceeded {
                Button("Skip") { step = .done }
            }
            Button(step == .done ? "Start using Speek" : "Continue") {
                if step == .done {
                    onFinish()
                } else {
                    if step == .permissions { onPermissionsGranted() }
                    step = Step(rawValue: step.rawValue + 1) ?? .done
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(step == .permissions && !requiredPermissionsGranted)
        }
    }
}

private struct OnboardingPermissionRow: View {
    let title: String
    let icon: String
    let granted: Bool
    let required: Bool
    let detail: String
    var hint: String?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .frame(width: 32)
                .foregroundStyle(granted ? .green : .primary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.semibold))
                    if !required {
                        Text("Recommended")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.quaternary))
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Label {
                        Text(hint)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "lightbulb.fill")
                    }
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 20))
            } else {
                Button("Grant…", action: action)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.4)))
        .animation(.easeInOut(duration: 0.2), value: hint != nil)
        .animation(.easeInOut(duration: 0.2), value: granted)
    }
}

// MARK: - Window controller

@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    private let session: DictationSession
    private let onPermissionsGranted: () -> Void

    init(session: DictationSession, onPermissionsGranted: @escaping () -> Void) {
        self.session = session
        self.onPermissionsGranted = onPermissionsGranted
    }

    /// Re-fronts the wizard (used when a permission grant lands while the
    /// user is off in System Settings).
    private func refocus() {
        show()
    }

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: OnboardingView(
                    session: session,
                    onPermissionsGranted: onPermissionsGranted,
                    // Same closure: attempting the tap start both registers
                    // Speek in the Input Monitoring list and, once granted,
                    // just works. Idempotent (HotkeyManager guards doubles).
                    onRequestInputMonitoring: onPermissionsGranted,
                    onRefocus: { [weak self] in self?.refocus() },
                    onFinish: { [weak self] in
                        SettingsStore.shared.onboardingCompleted = true
                        self?.window?.close()
                    }
                )
            )
            self.window = window
        }
        // Assigning a SwiftUI contentViewController resets the window frame
        // to zero until the first layout pass — so centering must not read
        // `frame` yet. Do NOT force layout here either: layoutIfNeeded() on a
        // window hosting a TextEditor deadlocks against TextKit's async
        // layout thread (observed: os_unfair_lock wait inside
        // NSTextContentStorage.documentRange). The content size is a known
        // constant, so just set it explicitly and center on that.
        window?.setContentSize(NSSize(width: 620, height: 520))
        window?.centerOnActiveScreen()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // Re-center after the present pass in case the hosting view resized
        // during its natural (asynchronous, deadlock-free) first layout.
        DispatchQueue.main.async { [weak self] in
            self?.window?.centerOnActiveScreen()
        }
    }
}
