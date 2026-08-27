import Combine
import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Checks the appcast at
/// SUFeedURL (see project.yml) on Sparkle's default schedule; updates are
/// EdDSA-signed and the DMGs are notarized, so installs are silent and safe.
///
/// Adopts Sparkle's gentle-reminder pattern for background (LSUIElement)
/// apps: scheduled update alerts for a menu-bar app can appear un-activated
/// behind other windows and get missed, so scheduled finds surface as a
/// menu-bar item instead (see MenuBarController) and Sparkle defers its UI
/// until the user engages.
@MainActor
final class UpdaterService: NSObject {
    static let shared = UpdaterService()

    /// Display version of a pending update ("1.4.0"); nil when none.
    let updateAvailable = CurrentValueSubject<String?, Never>(nil)

    private var controller: SPUStandardUpdaterController!

    override private init() {
        super.init()
        // startingUpdater: true begins the background check cycle immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
    }

    /// User-initiated check — shows UI for "no update available" too.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }
}

extension UpdaterService: SPUStandardUserDriverDelegate {
    // Sparkle invokes its user-driver delegate on the main thread; these are
    // nonisolated only to satisfy the ObjC protocol under Swift 6.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Scheduled (non-user-initiated) finds: raise the menu-bar reminder.
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            updateAvailable.send(version)
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            updateAvailable.send(nil)
        }
    }
}
