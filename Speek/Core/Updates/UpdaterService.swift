import Foundation
import Sparkle

/// Thin wrapper around Sparkle's standard updater. Checks the appcast at
/// SUFeedURL (see project.yml) on Sparkle's default schedule; updates are
/// EdDSA-signed and the DMGs are notarized, so installs are silent and safe.
@MainActor
final class UpdaterService {
    static let shared = UpdaterService()

    private let controller: SPUStandardUpdaterController

    private init() {
        // startingUpdater: true begins the background check cycle immediately.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
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
