import Foundation

/// Computes the visible slice of the spoken text around the word currently
/// being read, so the karaoke highlight always stays on screen even for long
/// passages. All offsets are UTF-16 (the coordinate space AVSpeechSynthesizer
/// reports word ranges in). Pure math — unit-tested.
enum SpokenTextWindow {
    struct Slice: Equatable {
        let before: String
        let current: String
        let after: String
        var isEmpty: Bool { before.isEmpty && current.isEmpty && after.isEmpty }
    }

    /// How far before the current word the window may start…
    static let maxBefore = 160
    /// …and how much upcoming text to show after it.
    static let maxAfter = 320

    static func slice(text: String, spokenRange: NSRange?) -> Slice {
        let ns = text as NSString
        guard let r = spokenRange,
              r.location != NSNotFound,
              r.location >= 0, r.length >= 0,
              r.location + r.length <= ns.length else {
            // Nothing spoken yet (or a stale range) — show the head of the text.
            return Slice(before: "", current: "", after: ns.substring(to: min(ns.length, maxAfter)))
        }

        // Window start: the beginning of the sentence containing the word,
        // clamped to at most maxBefore back so a single run-on sentence can't
        // flood the overlay.
        var start = max(0, r.location - maxBefore)
        let lookback = ns.substring(with: NSRange(location: start, length: r.location - start)) as NSString
        let terminators = CharacterSet(charactersIn: ".!?…\n")
        let lastTerminator = lookback.rangeOfCharacter(from: terminators, options: .backwards)
        if lastTerminator.location != NSNotFound {
            start += lastTerminator.location + lastTerminator.length
        }
        // Skip whitespace between the terminator and the sentence proper.
        while start < r.location,
              let scalar = Unicode.Scalar(ns.character(at: start)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            start += 1
        }

        let currentEnd = r.location + r.length
        let end = min(ns.length, currentEnd + maxAfter)
        return Slice(
            before: ns.substring(with: NSRange(location: start, length: r.location - start)),
            current: ns.substring(with: r),
            after: ns.substring(with: NSRange(location: currentEnd, length: end - currentEnd))
        )
    }
}
