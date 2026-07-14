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
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @State private var playgroundText = ""
    @State private var tryoutSucceeded = false
    @State private var refreshTimer: Timer?
    /// Tracks rows whose system prompt was already requested once — a second
    /// click falls through to opening System Settings directly (the OS won't
    /// re-show a dismissed prompt).
    @State private var requestedOnce: Set<String> = []

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
        .onAppear {
            perms.refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in PermissionsCoordinator.shared.refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        .onChange(of: session.state) { _, newState in
            // A dictation completed while the playground step is up → success.
            if step == .tryout, newState == .inserting || newState == .copied {
                tryoutSucceeded = true
            }
        }
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
                detail: "Captures your voice for on-device transcription."
            ) {
                Task {
                    // The native dialog resolves the await; only fall back to
                    // System Settings if the user previously denied (the OS
                    // won't re-show the dialog then).
                    await PermissionsCoordinator.shared.requestMic()
                    if !PermissionsCoordinator.shared.hasMic {
                        PermissionsCoordinator.shared.openSystemSettings(.microphone)
                    }
                }
            }
            OnboardingPermissionRow(
                title: "Input Monitoring",
                icon: "keyboard",
                granted: perms.hasInputMonitoring,
                required: true,
                detail: "Lets the global push-to-talk key work in any app."
            ) {
                if requestedOnce.insert("inputMonitoring").inserted {
                    PermissionsCoordinator.shared.requestInputMonitoring()
                } else {
                    perms.openSystemSettings(.inputMonitoring)
                }
            }
            OnboardingPermissionRow(
                title: "Accessibility",
                icon: "accessibility",
                granted: perms.hasAccessibility,
                required: false,
                detail: "Recommended — inserts text directly at your cursor and enables seamless sentence continuation."
            ) {
                // The AX prompt has its own "Open System Settings" button, so
                // never double-open; second click deep-links directly.
                if requestedOnce.insert("accessibility").inserted {
                    PermissionsCoordinator.shared.requestAccessibility()
                } else {
                    perms.openSystemSettings(.accessibility)
                }
            }
            Spacer()
        }
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
