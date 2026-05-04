import Foundation

protocol TextInjector: Sendable {
    /// Inserts text into the focused element. Throws if it cannot.
    func insert(_ text: String) async throws
}

enum InjectionError: Error {
    case unsupportedTarget
    case clipboardFailed
    case axDenied
}
