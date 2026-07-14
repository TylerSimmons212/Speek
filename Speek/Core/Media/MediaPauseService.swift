import AppKit
import Foundation

/// Pauses music players while the user dictates and resumes them afterward —
/// but only the ones *we* paused, so a player the user paused an hour ago
/// doesn't spontaneously start up when they finish talking.
///
/// Uses AppleScript against the two players that dominate real usage (Music,
/// Spotify). First use triggers a one-time macOS Automation permission prompt
/// per player ("Speek wants to control Spotify").
@MainActor
final class MediaPauseService {
    static let shared = MediaPauseService()

    private struct Player {
        let bundleID: String
        let scriptName: String
    }

    private let players: [Player] = [
        Player(bundleID: "com.apple.Music", scriptName: "Music"),
        Player(bundleID: "com.spotify.client", scriptName: "Spotify")
    ]

    /// Players paused by the most recent pausePlayingApps() call.
    private var pausedBundleIDs: Set<String> = []

    private init() {}

    /// Pauses any supported player that is currently playing. Cheap when no
    /// player is running (bundle check first — no AppleScript fired).
    func pausePlayingApps() {
        guard SettingsStore.shared.pauseMediaWhileDictating else { return }
        pausedBundleIDs = []
        for player in players where isRunning(player.bundleID) {
            let state = runScript("tell application \"\(player.scriptName)\" to player state as string")
            if state?.lowercased() == "playing" {
                _ = runScript("tell application \"\(player.scriptName)\" to pause")
                pausedBundleIDs.insert(player.bundleID)
                NSLog("MediaPauseService: paused \(player.scriptName)")
            }
        }
    }

    /// Resumes exactly the players we paused. No-op otherwise.
    func resumePausedApps() {
        guard !pausedBundleIDs.isEmpty else { return }
        for player in players where pausedBundleIDs.contains(player.bundleID) {
            // Player may have quit mid-dictation — don't relaunch it.
            guard isRunning(player.bundleID) else { continue }
            _ = runScript("tell application \"\(player.scriptName)\" to play")
            NSLog("MediaPauseService: resumed \(player.scriptName)")
        }
        pausedBundleIDs = []
    }

    private func isRunning(_ bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }

    private func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("MediaPauseService: AppleScript error \(error)")
            return nil
        }
        return result?.stringValue
    }
}
