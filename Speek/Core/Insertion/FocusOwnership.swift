import AppKit

/// Answers "is the dictation target one of our OWN windows?" — checked
/// first: AX queries against our own process are answered by our own main
/// thread, so a synchronous self-query or self-write deadlocks the app
/// (observed live: insertCore frozen in AXUIElementSetAttributeValue during
/// the onboarding tryout, which dictates into Speek's own TextEditor).
enum FocusOwnership {
    @MainActor
    static var ownWindowFocused: Bool {
        NSApp.isActive && NSApp.keyWindow != nil
    }
}
