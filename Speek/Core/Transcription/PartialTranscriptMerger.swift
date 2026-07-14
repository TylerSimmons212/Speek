import Foundation

/// Merges successive live-preview decodes into a display string that never
/// visibly "jumps": words the decoder has settled on are locked and won't
/// flicker when a later decode of the same audio re-words them, while the
/// trailing few words (the churn zone — where the decoder is still hearing
/// new audio) are free to rewrite.
///
/// Each preview tick re-transcribes the *entire* accumulated buffer, so every
/// decode is a fresh full-text hypothesis. Two rules keep the display calm:
///  1. The locked region never shrinks or changes. A glitch decode shorter
///     than the lock cannot erase committed words (the unlocked tail may
///     momentarily drop; the next full re-decode restores it).
///  2. If a new decode disagrees inside the locked region, the locked words
///     win and only the decode's words *beyond* the locked length are
///     appended.
struct PartialTranscriptMerger {
    /// Words that are committed and will no longer change on screen.
    private(set) var lockedWords: [String] = []
    /// What merge() last returned. An empty decode (silence, decoder hiccup)
    /// returns this unchanged rather than blanking the overlay.
    private var displayWords: [String] = []

    /// The last N displayed words stay unlocked — the decoder legitimately
    /// revises its most recent words as trailing audio context arrives.
    private let churnTail: Int

    init(churnTail: Int = 2) {
        self.churnTail = max(0, churnTail)
    }

    /// Feed the latest full-buffer decode; returns the string to display.
    mutating func merge(_ latest: String) -> String {
        let newWords = latest
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)

        guard !newWords.isEmpty else {
            return displayWords.joined(separator: " ")
        }

        let display: [String]
        let agreesWithLock = newWords.count >= lockedWords.count
            && zip(lockedWords, newWords).allSatisfy(==)

        if agreesWithLock {
            // Decode confirms everything we've locked — take it wholesale.
            display = newWords
        } else {
            // Decode is shorter than the lock, or rewrote locked territory.
            // Locked words win; graft on whatever the decode has beyond them.
            display = lockedWords + newWords.dropFirst(min(newWords.count, lockedWords.count))
        }

        // Advance the lock to cover all but the churn tail. Never retreat.
        let lockCount = max(lockedWords.count, display.count - churnTail)
        lockedWords = Array(display.prefix(lockCount))
        displayWords = display

        return display.joined(separator: " ")
    }
}
