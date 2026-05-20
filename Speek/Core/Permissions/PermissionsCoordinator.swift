import AVFoundation
import AppKit
import ApplicationServices
import Foundation
import FoundationModels
import IOKit.hid

@MainActor
final class PermissionsCoordinator: ObservableObject {
    static let shared = PermissionsCoordinator()

    @Published var hasMic: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published var hasInputMonitoring: Bool = false
    @Published var hasFoundationModels: Bool = false

    func refresh() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
        hasInputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        hasFoundationModels = SystemLanguageModel.default.isAvailable
    }

    func requestMic() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    func requestAccessibility() {
        // Standard "prompt with system UI" dance. The constant
        // kAXTrustedCheckOptionPrompt is exported as a `var` from C, which trips
        // Swift 6 strict-concurrency. Its value is documented as the literal
        // string "AXTrustedCheckOptionPrompt", so use that directly.
        let opts: [String: Any] = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(opts as CFDictionary)
    }

    /// Prompts for Input Monitoring permission, needed for the global
    /// flagsChanged CGEventTap that drives the push-to-talk hotkey.
    func requestInputMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    /// Deep-links into the relevant pane of System Settings → Privacy & Security.
    enum SettingsPane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    func openSystemSettings(_ pane: SettingsPane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
