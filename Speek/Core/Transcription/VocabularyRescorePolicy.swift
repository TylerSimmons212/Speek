import FluidAudio
import Foundation

/// Speek's text-side policy around FluidAudio's CTC vocabulary rescorer.
/// Pure, so it's unit-testable without models.
///
/// - `hasCandidate(in:)` is the preflight. With the spotter's acoustic-only
///   rescue disabled (see `VocabularyBooster.rescorerConfig`), the rescorer
///   only considers transcript spans whose string similarity to a term or
///   alias reaches its minimum similarity (and its guards only raise that
///   bar). When no span does, the rescorer can't change anything, so the
///   ~230 ms CTC pass is skipped. The check mirrors the rescorer's
///   normalization, Levenshtein similarity and threshold, and errs on the
///   side of running.
/// - `splice(_:into:)` applies accepted replacements to the decoder's own
///   text instead of taking the rescorer's rebuilt transcript. That keeps
///   punctuation the replaced span carried ("…Super Whisper." keeps its
///   period), and stops a replacement from swallowing an adjacent function
///   word ("the SuperWhisper" → "the Superwhisper", not "Superwhisper").
struct VocabularyRescorePolicy: Sendable {
    struct Replacement: Sendable, Equatable {
        /// The transcript words the rescorer replaced, as it reported them.
        let span: String
        /// The vocabulary term it chose.
        let term: String
    }

    private struct Form: Sendable {
        let spaced: [Unicode.Scalar]
        let joined: [Unicode.Scalar]
        let wordCount: Int
    }

    private let forms: [Form]
    /// Normalized canonical text → normalized canonical + alias forms.
    private let formsByTerm: [String: Set<String>]
    private let maxWindow: Int
    let threshold: Float

    init(context: CustomVocabularyContext) {
        var forms: [Form] = []
        var formsByTerm: [String: Set<String>] = [:]
        var seen = Set<String>()
        for term in context.terms {
            let canonical = Self.normalize(term.text)
            for text in [term.text] + (term.aliases ?? []) {
                let normalized = Self.normalize(text)
                guard !normalized.isEmpty else { continue }
                formsByTerm[canonical, default: []].insert(normalized)
                guard seen.insert(normalized).inserted else { continue }
                forms.append(Form(
                    spaced: Array(normalized.unicodeScalars),
                    joined: Array(normalized.replacingOccurrences(of: " ", with: "").unicodeScalars),
                    wordCount: normalized.split(separator: " ").count
                ))
            }
        }
        self.forms = forms
        self.formsByTerm = formsByTerm
        // The rescorer builds spans up to a form's word count and compounds of
        // up to three words. One extra word of slack.
        self.maxWindow = max(3, forms.map(\.wordCount).max() ?? 1) + 1
        self.threshold = Self.minimumSimilarity(for: context)
    }

    /// The lowest similarity the rescorer accepts for this vocabulary: what
    /// `VocabularyBoostingSession.rescore` passes as `minSimilarity`. Terms
    /// carry no per-term override in Speek.
    static func minimumSimilarity(for context: CustomVocabularyContext) -> Float {
        max(
            ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count).minSimilarity,
            context.minSimilarity
        )
    }

    // MARK: - Preflight

    /// Whether any span of `transcript` is similar enough to a term or alias
    /// for the rescorer to consider it.
    func hasCandidate(in transcript: String) -> Bool {
        let words = Self.normalize(transcript).split(separator: " ").map(String.init)
        guard !words.isEmpty, !forms.isEmpty else { return false }
        for start in words.indices {
            for length in 1...min(maxWindow, words.count - start) {
                let window = words[start..<(start + length)]
                let spaced = Array(window.joined(separator: " ").unicodeScalars)
                let joined = Array(window.joined().unicodeScalars)
                for form in forms {
                    for (a, b) in [(spaced, form.spaced), (joined, form.joined), (joined, form.spaced)]
                    where Self.similarity(a, b, atLeast: threshold) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Splice

    /// `transcript` with each replacement applied in place. A replacement
    /// whose span can't be found, or that only fits by padding a function
    /// word onto a shorter phrase, is dropped. Dropping is the safe direction:
    /// the decoder's text stands.
    func splice(_ replacements: [Replacement], into transcript: String) -> String {
        let words = transcript.split(whereSeparator: \.isWhitespace)
        var used = Set<Int>()
        var edits: [(range: Range<String.Index>, text: String)] = []

        for replacement in replacements {
            let spanWords = replacement.span.split(whereSeparator: \.isWhitespace)
            guard !spanWords.isEmpty, spanWords.count <= words.count else { continue }
            let starts = 0...(words.count - spanWords.count)
            func matches(_ i: Int, _ equal: (Substring, Substring) -> Bool) -> Bool {
                spanWords.indices.allSatisfy { j in
                    !used.contains(i + j) && equal(words[i + j], spanWords[j])
                }
            }
            guard let start = starts.first(where: { matches($0, ==) })
                ?? starts.first(where: { matches($0) { Self.normalize($0) == Self.normalize($1) } })
            else { continue }

            let end = start + spanWords.count
            let range = words[start].startIndex..<words[end - 1].endIndex
            guard let rewritten = rewrite(span: transcript[range], term: replacement.term) else { continue }
            used.formUnion(start..<end)
            edits.append((range, rewritten))
        }

        var out = ""
        var cursor = transcript.startIndex
        for edit in edits.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            out += transcript[cursor..<edit.range.lowerBound]
            out += edit.text
            cursor = edit.range.upperBound
        }
        out += transcript[cursor...]
        return out
    }

    /// Words that read as padding when they sit at the edge of a replaced span.
    static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "nor", "so", "of", "to", "in", "on", "at",
        "for", "with", "by", "from", "as", "into", "is", "are", "was", "were", "be",
        "it", "its", "this", "that", "my", "your", "our", "their", "his", "her",
    ]

    /// The span rewritten around `term`, or nil to keep the span as is.
    private func rewrite(span: Substring, term: String) -> String? {
        let words = span.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return nil }
        let canonical = Self.normalize(term)

        // The whole span is the term or one of its configured aliases: replace
        // all of it, even a function word ("to be" → "Toby").
        var lo = 0
        var hi = words.count
        if !(formsByTerm[canonical]?.contains(Self.normalize(String(span))) ?? false) {
            let termWords = Set(canonical.split(separator: " ").map(String.init))
            func isPadding(_ word: Substring) -> Bool {
                let normalized = Self.normalize(String(word))
                return Self.functionWords.contains(normalized) && !termWords.contains(normalized)
            }
            while lo < hi, isPadding(words[lo]) { lo += 1 }
            while hi > lo, isPadding(words[hi - 1]) { hi -= 1 }
            guard lo < hi else { return nil }
            // A function word was what made the span long enough for a
            // multi-word term ("whisper the" → "Wispr Flow"). Not a real match.
            if lo > 0 || hi < words.count, hi - lo < termWords.count { return nil }
        }

        let core = span[words[lo].startIndex..<words[hi - 1].endIndex]
        let opening = core.prefix(while: { Self.openingPunctuation.contains($0) })
        let closing = String(core.reversed().prefix(while: { Self.closingPunctuation.contains($0) }).reversed())
        var replacement = term
        if !opening.isEmpty, !term.hasPrefix(opening) { replacement = String(opening) + replacement }
        if !closing.isEmpty, !term.hasSuffix(closing) { replacement += closing }

        var out = String(span)
        let offset = span.distance(from: span.startIndex, to: core.startIndex)
        let lower = out.index(out.startIndex, offsetBy: offset)
        let upper = out.index(lower, offsetBy: core.count)
        out.replaceSubrange(lower..<upper, with: replacement)
        return out
    }

    private static let openingPunctuation: Set<Character> = ["\"", "'", "(", "[", "“", "‘"]
    private static let closingPunctuation: Set<Character> = [
        ".", ",", "!", "?", ";", ":", "…", "\"", "'", ")", "]", "”", "’",
    ]

    // MARK: - Text utilities (mirroring FluidAudio's VocabularyRescorer)

    /// Lowercased; letters, digits, apostrophes and hyphens kept; other
    /// punctuation dropped; whitespace collapsed to single spaces.
    static func normalize<S: StringProtocol>(_ text: S) -> String {
        var out = ""
        var pendingSpace = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber || character == "'" || character == "-" {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
            } else if character.isWhitespace {
                pendingSpace = true
            }
        }
        return out
    }

    /// `1 - levenshtein / maxLength`, FluidAudio's string similarity.
    static func similarity<C: Equatable>(_ a: [C], _ b: [C]) -> Float {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return 1 }
        return 1 - Float(levenshtein(a, b)) / Float(longest)
    }

    /// `similarity(a, b) >= threshold`, without finishing the edit distance
    /// once it can no longer get under the allowed bound.
    static func similarity<C: Equatable>(_ a: [C], _ b: [C], atLeast threshold: Float) -> Bool {
        let longest = max(a.count, b.count)
        guard longest > 0 else { return true }
        // Epsilon so float rounding can only widen the bound (run, not skip).
        let allowed = Int(((1 - threshold) * Float(longest) + 1e-4).rounded(.down))
        // Distance is at least the length gap.
        guard abs(a.count - b.count) <= allowed else { return false }
        return levenshtein(a, b, bound: allowed) <= allowed
    }

    /// Edit distance, or any value above `bound` as soon as every path
    /// exceeds it.
    private static func levenshtein<C: Equatable>(_ a: [C], _ b: [C], bound: Int = .max) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > bound { return rowMin }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
