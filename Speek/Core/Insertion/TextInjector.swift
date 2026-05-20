import Foundation

enum InjectionResult {
    /// Text was written directly into the focused field.
    case inserted
    /// No editable field was focused; text was placed on the clipboard only.
    case copied
}

protocol TextInjector: Sendable {
    /// Inserts text into the focused element, or places it on the clipboard if
    /// no editable target is available. Throws on hard failures (e.g., clipboard
    /// write rejection).
    func insert(_ text: String) async throws -> InjectionResult
}

enum InjectionError: Error {
    case unsupportedTarget
    case clipboardFailed
    case axDenied
}
