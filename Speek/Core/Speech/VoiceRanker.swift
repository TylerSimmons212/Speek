import Foundation

/// Pure ranking logic for auto-picking the best installed system voice.
/// Separated from AVFoundation lookups so it's unit-testable.
enum VoiceRanker {
    struct Candidate: Equatable {
        let identifier: String
        let language: String   // BCP-47, e.g. "en-US"
        let quality: Int       // 1 default, 2 enhanced, 3 premium
        let name: String
        let isNovelty: Bool
        let isPersonalVoice: Bool
    }

    /// Best voice for the user's language. Locale fit dominates (exact
    /// "en-US" beats any other-region English, which beats other languages),
    /// then quality (Premium > Enhanced > default), then name for stable
    /// ties. Novelty voices (Bells, Zarvox…) are never auto-picked, and
    /// neither is a Personal Voice — that one is a deliberate opt-in via the
    /// Settings picker, not a surprise.
    static func best(from candidates: [Candidate], preferredLanguage: String) -> Candidate? {
        let usable = candidates.filter { !$0.isNovelty && !$0.isPersonalVoice }
        let preferredPrimary = primaryCode(preferredLanguage)

        func languageScore(_ c: Candidate) -> Int {
            if c.language.caseInsensitiveCompare(preferredLanguage) == .orderedSame { return 2 }
            if primaryCode(c.language) == preferredPrimary { return 1 }
            return 0
        }

        // max(by:) wants "a is less than b" — return true when a is WORSE.
        return usable.max { a, b in
            let la = languageScore(a), lb = languageScore(b)
            if la != lb { return la < lb }
            if a.quality != b.quality { return a.quality < b.quality }
            return a.name > b.name  // alphabetically-first name wins ties
        }
    }

    /// "en-US" → "en". Tolerates underscores ("en_US") since locale
    /// identifiers show up both ways.
    static func primaryCode(_ languageTag: String) -> String {
        let normalized = languageTag.replacingOccurrences(of: "_", with: "-")
        return normalized.split(separator: "-").first.map { $0.lowercased() } ?? normalized.lowercased()
    }
}
