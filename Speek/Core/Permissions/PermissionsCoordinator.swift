import AVFoundation
import ApplicationServices
import Foundation
import FoundationModels

@MainActor
final class PermissionsCoordinator: ObservableObject {
    @Published var hasMic: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published var hasFoundationModels: Bool = false

    func refresh() {
        hasMic = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        hasAccessibility = AXIsProcessTrusted()
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
}
