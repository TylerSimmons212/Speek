import AppKit
import ApplicationServices
import Foundation

/// Watches the focused text field for a short window after Speek inserts a
/// transcription. If the user manually fixes a single word inside the inserted
/// region, that pair is added to `SettingsStore.customReplacements` so the next
/// dictation produces the corrected spelling directly.
///
/// Scope is deliberately tight — we only auto-learn from clean single-word
/// substitutions inside our own inserted text. Anything else (multiple changes,
/// insertions, deletions, casing-only edits, very short words) is ignored. This
/// keeps false positives low so the user's vocabulary stays trustworthy.
@MainActor
final class CorrectionLearner: ObservableObject {
    static let shared = CorrectionLearner()

    /// Set briefly whenever we just learned a new word; the overlay reads this
    /// to show a "Learned X → Y" pill with an undo button. Cleared after a few
    /// seconds, or immediately when the user hits undo.
    @Published private(set) var lastLearned: WordDiff?

    private struct Snapshot {
        let element: AXUIElement
        let postInsertionText: String
        let insertedText: String
    }

    /// Watch the field for at most this long total. Gives up if the user just
    /// never edits.
    private let maxWatchDuration: TimeInterval = 60
    /// How long the field has to stay unchanged after the last edit before we
    /// commit the learn. Lets users finish typing/deleting at their own pace.
    private let editStableThreshold: TimeInterval = 2.5
    /// Polling cadence while watching.
    private let pollInterval: TimeInterval = 0.4
    /// How long to keep the "learned" pill visible before auto-dismiss.
    private let learnedFeedbackDuration: TimeInterval = 8

    private var pendingCheck: Task<Void, Never>?
    private var feedbackTimer: Task<Void, Never>?
    private var snapshot: Snapshot?

    /// Called immediately after a successful AX/clipboard insertion. Begins a
    /// background watcher that polls the focused field and commits a learn only
    /// once the user has been still for `editStableThreshold` seconds.
    func recordInsertion(insertedText: String) {
        pendingCheck?.cancel()
        snapshot = nil

        guard SettingsStore.shared.learnFromCorrections else { return }
        // Never watch our own windows — the polling reads are self-AX
        // queries, which deadlock against our own main thread.
        guard !FocusOwnership.ownWindowFocused else { return }
        guard let element = Self.focusedAXElement() else { return }
        guard let postInsertionText = Self.readAXValue(element) else { return }

        let snap = Snapshot(
            element: element,
            postInsertionText: postInsertionText,
            insertedText: insertedText
        )
        self.snapshot = snap

        let pollNs = UInt64(pollInterval * 1_000_000_000)
        let stable = editStableThreshold
        let maxDuration = maxWatchDuration

        pendingCheck = Task { [weak self] in
            var lastSeen = snap.postInsertionText
            var lastChangeAt: Date?
            let start = Date()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollNs)
                if Task.isCancelled { return }
                if Date().timeIntervalSince(start) > maxDuration { return }

                let current = await MainActor.run { Self.readAXValue(snap.element) }
                guard let current else { return } // field went away

                if current != lastSeen {
                    lastSeen = current
                    lastChangeAt = Date()
                    continue
                }
                if let lastChange = lastChangeAt,
                   Date().timeIntervalSince(lastChange) >= stable {
                    await self?.commitLearn(currentText: current)
                    return
                }
            }
        }
    }

    private func commitLearn(currentText: String) {
        guard let snap = snapshot else { return }
        snapshot = nil
        runCheckCore(snapshot: snap, currentText: currentText)
    }

    /// Cancels any pending check — called when a new recording starts, since
    /// the user is clearly moving on.
    func cancelPendingCheck() {
        pendingCheck?.cancel()
        pendingCheck = nil
        snapshot = nil
    }

    // MARK: - Diff check

    private func runCheckCore(snapshot snap: Snapshot, currentText: String) {
        guard currentText != snap.postInsertionText else { return }

        // Find the single-token diff and (if it looks like a proper noun) the
        // contiguous capitalized phrase it belongs to. This keeps multi-word
        // names like "Wispr Flow" intact instead of learning just "Wispr".
        guard let pair = Self.learnedPhrase(
            from: snap.postInsertionText,
            to: currentText
        ) else { return }

        // Only learn when the original was part of our own insertion.
        guard snap.insertedText.range(of: pair.original, options: .caseInsensitive) != nil else { return }
        // Require ≥3-char keys so we don't learn from "to" → "too" etc.
        guard pair.original.count >= 3 else { return }
        // Don't learn casing-only changes — RuleStage handles those.
        guard pair.original.lowercased() != pair.replacement.lowercased() else { return }
        // Don't learn if the user already has a mapping for this phrase.
        var vocab = SettingsStore.shared.customReplacements
        guard vocab[pair.original] == nil else { return }

        vocab[pair.original] = pair.replacement
        SettingsStore.shared.customReplacements = vocab
        NSLog("CorrectionLearner: learned '\(pair.original)' → '\(pair.replacement)'")
        showFeedback(for: pair)
    }

    /// Removes the most recently learned pair from the user's vocabulary and
    /// clears the feedback pill. Called when the user taps the × button.
    func undoLastLearned() {
        guard let diff = lastLearned else { return }
        var vocab = SettingsStore.shared.customReplacements
        if vocab[diff.original] == diff.replacement {
            vocab.removeValue(forKey: diff.original)
            SettingsStore.shared.customReplacements = vocab
        }
        lastLearned = nil
        feedbackTimer?.cancel()
        feedbackTimer = nil
    }

    private func showFeedback(for diff: WordDiff) {
        lastLearned = diff
        feedbackTimer?.cancel()
        let duration = learnedFeedbackDuration
        feedbackTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if self?.lastLearned == diff { self?.lastLearned = nil }
            }
        }
    }

    // MARK: - Helpers

    struct WordDiff: Equatable {
        let original: String
        let replacement: String
    }

    /// Returns the substitution if `a` and `b` tokenize to the same word count
    /// and differ at exactly one position; nil otherwise.
    nonisolated static func detectSingleWordSubstitution(from a: String, to b: String) -> WordDiff? {
        let aWords = tokenize(a)
        let bWords = tokenize(b)
        guard let i = singleDiffIndex(aWords, bWords) else { return nil }
        return WordDiff(original: aWords[i], replacement: bWords[i])
    }

    /// Like `detectSingleWordSubstitution`, but if the changed token looks like
    /// part of a multi-word proper noun (e.g. "Wispr" in "Wispr Flow"), the
    /// returned pair covers the whole contiguous capitalized phrase. This keeps
    /// learned vocabulary tied to its context — fixing "Whisper" inside "Whisper
    /// Flow" learns the full name, not the bare word.
    nonisolated static func learnedPhrase(from a: String, to b: String) -> WordDiff? {
        let aWords = tokenize(a)
        let bWords = tokenize(b)
        guard let i = singleDiffIndex(aWords, bWords) else { return nil }

        // Punctuation-stripped check so "Flow," still counts as a proper noun.
        let isProperNoun: (String) -> Bool = { token in
            let stripped = stripEdgePunctuation(token)
            return stripped.first?.isUppercase == true
        }

        guard isProperNoun(bWords[i]) else {
            return WordDiff(original: aWords[i], replacement: bWords[i])
        }

        var start = i
        var end = i
        // Extend forward through adjacent capitalized tokens.
        while end + 1 < bWords.count, isProperNoun(bWords[end + 1]) {
            end += 1
        }
        // Extend backward — but stop at sentence-initial words (which may be
        // capitalized only because they start the sentence, not because they're
        // part of a name).
        while start > 0, isProperNoun(bWords[start - 1]) {
            if start - 1 == 0 { break }
            let prev = stripEdgePunctuation(bWords[start - 2])
            if let last = prev.last, ".!?".contains(last) { break }
            start -= 1
        }

        let aPhrase = assemblePhrase(aWords[start...end])
        let bPhrase = assemblePhrase(bWords[start...end])
        return WordDiff(original: aPhrase, replacement: bPhrase)
    }

    /// Returns the index of the single differing token, or nil if zero or
    /// multiple tokens differ (or the token counts disagree).
    nonisolated private static func singleDiffIndex(_ a: [String], _ b: [String]) -> Int? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        var diffIndex: Int?
        for i in a.indices where a[i] != b[i] {
            if diffIndex != nil { return nil }
            diffIndex = i
        }
        return diffIndex
    }

    /// Joins a slice into a phrase, trimming trailing punctuation from the last
    /// token so we don't bake commas / periods into the learned key.
    nonisolated private static func assemblePhrase(_ slice: ArraySlice<String>) -> String {
        var tokens = Array(slice)
        if let last = tokens.last {
            tokens[tokens.count - 1] = stripTrailingPunctuation(last)
        }
        return tokens.joined(separator: " ")
    }

    nonisolated private static func stripTrailingPunctuation(_ s: String) -> String {
        let set: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", ")", "]"]
        var end = s.endIndex
        while end > s.startIndex {
            let prev = s.index(before: end)
            guard set.contains(s[prev]) else { break }
            end = prev
        }
        return String(s[..<end])
    }

    nonisolated private static func stripEdgePunctuation(_ s: String) -> String {
        let set: Set<Character> = [".", ",", ";", ":", "!", "?", "\"", "'", "(", "[", ")", "]"]
        let trimmed = s.drop(while: { set.contains($0) })
        return stripTrailingPunctuation(String(trimmed))
    }

    /// Splits on whitespace; punctuation stays attached to its word. Good
    /// enough for word-level diffing of short transcript inserts.
    nonisolated private static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
    }

    private static func focusedAXElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focused)
        guard err == .success, let element = focused else { return nil }
        // swiftlint:disable:next force_cast
        return (element as! AXUIElement)
    }

    private static func readAXValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        guard err == .success else { return nil }
        return value as? String
    }
}
