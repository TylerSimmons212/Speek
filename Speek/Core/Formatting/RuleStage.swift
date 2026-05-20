import Foundation

/// Deterministic, fast (<10ms) cleanup pass.
/// - Strips filler words (um, uh, er, ah).
/// - Collapses immediately-repeated words.
/// - Resolves self-corrections inline ("Friday, actually Saturday" → "Saturday").
/// - Capitalizes sentence starts.
/// - Applies user-defined custom replacements (case-insensitive match, case-aware replacement).
struct RuleStage {
    struct Result {
        let text: String
        /// True if the input contained a correction marker that the regex couldn't
        /// confidently resolve. The pipeline uses this to decide whether to fall
        /// through to the LLM polish stage.
        let possibleAmbiguousCorrection: Bool
    }

    private let fillers: Set<String> = ["um", "uh", "er", "ah"]
    let customReplacements: [String: String]

    init(customReplacements: [String: String] = [:]) {
        self.customReplacements = customReplacements
    }

    /// Marker phrases a speaker uses to retract what they just said and replace it.
    /// Longer phrases first so they win over their substrings.
    private static let correctionMarkerPattern: NSRegularExpression = {
        let markers = [
            "sorry,?\\s+i\\s+meant",
            "no\\s+wait",
            "wait\\s+no",
            "scratch\\s+that",
            "or\\s+rather",
            "make\\s+that",
            "i\\s+meant",
            "i\\s+mean",
            "actually",
            "wait"
        ]
        let pattern = "(?i),?\\s+(?:\(markers.joined(separator: "|")))[,\\s]+"
        return try! NSRegularExpression(pattern: pattern)
    }()

    func process(_ input: String) -> Result {
        guard !input.isEmpty else { return Result(text: input, possibleAmbiguousCorrection: false) }
        var s = input

        // 1. Custom replacements (case-insensitive whole-word).
        for (needle, replacement) in customReplacements {
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: needle))\\b"
            s = s.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: [.regularExpression, .caseInsensitive]
            )
        }

        // 2. Voice commands → punctuation/structure.
        s = applyVoiceCommands(s)

        // 3. Spoken numbers / dates → digits. Runs BEFORE dedupe so phrases
        // like "twenty twenty four" survive the repeated-word collapse.
        s = NumberFormatStage.run(s)

        // 4. Strip fillers (whole-word, case-insensitive).
        let fillerPattern = "\\b(\(fillers.joined(separator: "|")))\\b"
        s = s.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 5. Collapse repeated whole words.
        s = s.replacingOccurrences(
            of: "\\b(\\w+)(\\s+\\1\\b)+",
            with: "$1",
            options: .regularExpression
        )

        // 6. Tidy spacing introduced by command/punctuation substitutions.
        s = tidySpacing(s)

        // 7. Resolve self-corrections inline where possible.
        let resolved = resolveCorrections(s)
        s = resolved.text

        // 8. Capitalize first letter of each sentence.
        s = capitalizeSentences(s)
        return Result(text: s, possibleAmbiguousCorrection: resolved.ambiguous)
    }

    /// Translates dictated phrases to punctuation / structural marks.
    /// Order matters: longer phrases first so they win.
    private func applyVoiceCommands(_ input: String) -> String {
        let commands: [(pattern: String, replacement: String)] = [
            ("(?i)\\bnew\\s+paragraph\\b", "\n\n"),
            ("(?i)\\bnew\\s+line\\b", "\n"),
            ("(?i)\\bopen\\s+quote\\b", " \""),
            ("(?i)\\bclose\\s+quote\\b", "\" "),
            ("(?i)\\bopen\\s+paren(thesis)?\\b", " ("),
            ("(?i)\\bclose\\s+paren(thesis)?\\b", ") "),
            ("(?i)\\b(period|full\\s+stop)\\b", "."),
            ("(?i)\\bcomma\\b", ","),
            ("(?i)\\bquestion\\s+mark\\b", "?"),
            ("(?i)\\bexclamation\\s+(mark|point)\\b", "!"),
            ("(?i)\\bsemicolon\\b", ";"),
            ("(?i)\\bcolon\\b", ":"),
            ("(?i)\\bdash\\b", " — "),
            ("(?i)\\bhyphen\\b", "-"),
            ("(?i)\\bellipsis\\b", "…")
        ]
        var s = input
        for (pattern, replacement) in commands {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }

    /// Cleans up double-spaces and stray spaces before punctuation introduced
    /// when the voice-command substitutions ran.
    private func tidySpacing(_ input: String) -> String {
        var s = input
        // Space before punctuation → no space.
        s = s.replacingOccurrences(of: "\\s+([,.;:!?…])", with: "$1", options: .regularExpression)
        // Multiple spaces → single space.
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        // Trim space around newlines.
        s = s.replacingOccurrences(of: "[ \\t]*\n[ \\t]*", with: "\n", options: .regularExpression)
        // Final trim.
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Backward-compatible convenience: returns just the cleaned text.
    func run(_ input: String) -> String { process(input).text }

    /// Rewrites "X, MARKER Y" patterns:
    /// - Short Y (≤2 words) with longer X → replace trailing words of X with Y.
    /// - Long Y (≥3 words) → assume full-clause rewrite, fall back to last sentence
    ///   boundary in X and prepend that, then use Y.
    /// - Otherwise flag ambiguous and leave for the LLM.
    private func resolveCorrections(_ input: String) -> (text: String, ambiguous: Bool) {
        let nsRange = NSRange(input.startIndex..., in: input)
        guard let match = Self.correctionMarkerPattern.firstMatch(in: input, range: nsRange),
              let matchRange = Range(match.range, in: input) else {
            return (input, false)
        }

        let before = String(input[input.startIndex..<matchRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(input[matchRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let beforeWords = before.split(whereSeparator: { $0.isWhitespace })
        let afterWords = after.split(whereSeparator: { $0.isWhitespace })

        guard !afterWords.isEmpty else { return (before, false) }

        if afterWords.count <= 2 && beforeWords.count > afterWords.count {
            let keep = beforeWords.dropLast(afterWords.count).joined(separator: " ")
            let resolved = keep.isEmpty ? after : "\(keep) \(after)"
            return (resolved, false)
        }

        if afterWords.count >= 3 {
            let clauseStart = findClauseStart(in: before)
            let preClause = String(before[..<clauseStart])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let resolved = preClause.isEmpty ? after : "\(preClause) \(after)"
            return (resolved, false)
        }

        return (input, true)
    }

    private func findClauseStart(in text: String) -> String.Index {
        for terminator in [". ", "! ", "? "] {
            if let range = text.range(of: terminator, options: .backwards) {
                return range.upperBound
            }
        }
        return text.startIndex
    }

    private func capitalizeSentences(_ input: String) -> String {
        var chars = Array(input)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" || c == "\n" {
                capitalizeNext = true
            } else if !c.isWhitespace {
                capitalizeNext = false
            }
        }
        return String(chars)
    }
}
