import AppKit

/// Picks s1-mini's control line from the app receiving the dictation, so a
/// Slack message reads like a chat message and a dictated email gets real
/// email layout. Deliberately small: unknown apps get standard prose.
///
/// Mapping notes, from probing the real model:
/// - Chat → semi-casual: lowercase sentence starts, no trailing period, but
///   "I", names, and apostrophes intact. (`casual` also strips apostrophes —
///   "dont", "ill" — too aggressive to apply implicitly.)
/// - Mail → email context: a dictated whole email gets greeting / body /
///   sign-off blocks; a single sentence dictated mid-draft passes through
///   unchanged, so it's safe for replies and edits.
/// - `lists` is never mapped: s1-mini already bullets 3+ enumerated items
///   under `prose`, so it showed no difference.
enum AppPolishStyle {
    static let chat = PolishStyle(styling: .semiCasual)
    static let email = PolishStyle(context: .email)

    static let chatBundleIDs: Set<String> = [
        "com.apple.MobileSMS",               // Messages
        "com.tinyspeck.slackmacgap",         // Slack
        "com.hnc.Discord",                   // Discord
        "ru.keepcoder.Telegram",             // Telegram (App Store)
        "org.telegram.desktop",              // Telegram Desktop
        "net.whatsapp.WhatsApp",             // WhatsApp
        "org.whispersystems.signal-desktop", // Signal
        "com.microsoft.teams2",              // Microsoft Teams
        "com.microsoft.teams",               // Microsoft Teams (classic)
    ]

    static let emailBundleIDs: Set<String> = [
        "com.apple.mail",                    // Mail
        "com.microsoft.Outlook",             // Outlook
        "com.readdle.SparkDesktop",          // Spark
        "com.readdle.smartemail-Mac",        // Spark (classic)
        "com.superhuman.electron",           // Superhuman
        "com.mimestream.Mimestream",         // Mimestream
        "it.bloop.airmail2",                 // Airmail
    ]

    static func style(forBundleID bundleID: String?) -> PolishStyle {
        guard let bundleID else { return .standard }
        if chatBundleIDs.contains(bundleID) { return chat }
        if emailBundleIDs.contains(bundleID) { return email }
        return .standard
    }

    /// Style for the app that will receive the insertion (the frontmost
    /// app), or standard prose when app matching is off in Settings.
    @MainActor
    static func current() -> PolishStyle {
        guard SettingsStore.shared.matchStyleToApp else { return .standard }
        return style(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }
}
