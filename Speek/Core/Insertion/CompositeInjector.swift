import Foundation
import os

final class CompositeInjector: TextInjector {
    private let primary: TextInjector
    private let fallback: TextInjector
    private let log = Logger(subsystem: "com.tylersimmons.speek", category: "injection")

    init(primary: TextInjector = AXInjector(), fallback: TextInjector = ClipboardInjector()) {
        self.primary = primary
        self.fallback = fallback
    }

    func insert(_ text: String) async throws {
        let useAX = await MainActor.run { SettingsStore.shared.axInsertionEnabled }
        if useAX {
            do {
                try await primary.insert(text)
                log.debug("AX injection succeeded")
                return
            } catch {
                log.debug("AX injection failed (\(String(describing: error))) — falling back to clipboard")
            }
        }
        try await fallback.insert(text)
    }
}
