import SwiftUI
import AppKit

/// Hotkey picker shared by onboarding and Settings: quick-pick chips for the
/// common choices plus a "press any key" recorder for everything else.
///
/// The recorder uses a LOCAL event monitor — it only sees events while our
/// window is key, so it needs no Input Monitoring permission and can run
/// before any permissions are granted (important: onboarding uses it on a
/// step before the tryout).
struct HotkeyRecorderView: View {
    @Binding var binding: HotkeyBinding

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var message: String?

    private static let quickPicks: [HotkeyBinding] = [.fn, .rightCommand, .rightOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(Self.quickPicks, id: \.self) { pick in
                    chip(for: pick)
                }
                recordChip
            }
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func chip(for pick: HotkeyBinding) -> some View {
        let selected = binding == pick && !isRecording
        return Button {
            stopRecording()
            message = nil
            binding = pick
        } label: {
            Text(pick.displayName)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(selected ? Color.accentColor : Color.secondary.opacity(0.15)))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    private var recordChip: some View {
        let customSelected = !Self.quickPicks.contains(binding) && !isRecording
        return Button {
            isRecording ? stopRecording() : startRecording()
        } label: {
            Text(isRecording ? "Press a key…" : (customSelected ? binding.displayName : "Custom…"))
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(
                        isRecording ? Color.orange :
                        customSelected ? Color.accentColor : Color.secondary.opacity(0.15)
                    )
                )
                .foregroundStyle(isRecording || customSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Capture

    private func startRecording() {
        message = nil
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            handle(event)
            return nil // consume while recording
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let keyCode = event.keyCode
            guard let flag = HotkeyBinding.modifierFlag(forKeyCode: keyCode) else { return }
            // Accept on the press edge only (flags gained the family bit).
            let familyDown: Bool
            switch flag {
            case .maskSecondaryFn: familyDown = event.modifierFlags.contains(.function)
            case .maskCommand: familyDown = event.modifierFlags.contains(.command)
            case .maskAlternate: familyDown = event.modifierFlags.contains(.option)
            case .maskControl: familyDown = event.modifierFlags.contains(.control)
            case .maskShift: familyDown = event.modifierFlags.contains(.shift)
            default: familyDown = false
            }
            guard familyDown else { return }
            binding = .modifier(flagRawValue: flag.rawValue, keyCode: keyCode)
            message = nil
            stopRecording()

        case .keyDown:
            if event.keyCode == 53 { // Escape cancels
                stopRecording()
                return
            }
            if HotkeyBinding.functionKeyCodes.contains(event.keyCode) {
                binding = .functionKey(keyCode: event.keyCode)
                message = nil
                stopRecording()
            } else {
                message = "Use a modifier key (Fn, ⌘, ⌥, ⌃, ⇧) or F13–F20. Regular keys can't be used — they'd type characters while you dictate."
            }

        default:
            break
        }
    }
}
