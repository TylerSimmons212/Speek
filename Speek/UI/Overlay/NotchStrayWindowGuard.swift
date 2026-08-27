import AppKit
import DynamicNotchKit
import SwiftUI

/// Works around a DynamicNotchKit 1.1.0 bug (latest release as of Aug 2026):
/// on `NSApplication.didChangeScreenParametersNotification` — display
/// plug/unplug, wake, resolution change — the kit re-creates its panel on
/// `NSScreen.screens.first` and orders it front, even while the notch is
/// hidden. Its `hide()` then early-returns because the internal state is
/// already `.hidden`, so the stray panel is never cleaned up — leaving a
/// dead virtual notch at the top of (usually) the external display.
///
/// The kit's `state` is internal, so each overlay controller supplies its
/// own "should this notch be hidden right now?" answer; after a screen
/// change, the guard closes the panel whenever the notch is supposed to be
/// hidden. `windowController` is public and settable, which makes the
/// teardown possible from outside the kit.
@MainActor
final class NotchStrayWindowGuard {
    private var watchTask: Task<Void, Never>?

    init<Expanded: View, CompactLeading: View, CompactTrailing: View>(
        notch: DynamicNotch<Expanded, CompactLeading, CompactTrailing>,
        shouldBeHidden: @escaping @MainActor () -> Bool
    ) {
        watchTask = Task { [weak notch] in
            let changes = NotificationCenter.default
                .notifications(named: NSApplication.didChangeScreenParametersNotification)
                .map(\.name) // Notification itself isn't Sendable
            for await _ in changes {
                // The kit's own observer re-creates the panel asynchronously;
                // run after it so we close the stray, not a panel it is
                // about to replace.
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                guard let notch else { return }
                guard shouldBeHidden(), let windowController = notch.windowController else { continue }
                windowController.close()
                notch.windowController = nil
            }
        }
    }

    deinit {
        watchTask?.cancel()
    }
}
