import Foundation

/// Deterministic, fast (<10ms) pre-model pass. Only what MUST be exact and
/// user-controlled lives here — everything language-shaped (fillers,
/// self-corrections, spoken numbers, punctuation, casing) is s1-mini's job:
/// - Custom vocabulary replacements (case-insensitive match), including
///   spellings learned by CorrectionLearner — the model can't know these.
/// - Dictated punctuation/structure commands ("new line", "period").
/// - Basic filler stripping, repeated-word collapse, and sentence casing, so
///   the fallback path (model disabled or not yet downloaded) stays readable.
struct RuleStage {
    private let fillers: Set<String> = ["um", "uh", "er", "ah"]
    let customReplacements: [String: String]

    init(customReplacements: [String: String] = [:]) {
        self.customReplacements = customReplacements
    }

    func run(_ input: String) -> String {
        guard !input.isEmpty else { return input }
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

        // 3. Strip fillers (whole-word, case-insensitive).
        let fillerPattern = "\\b(\(fillers.joined(separator: "|")))\\b"
        s = s.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 4. Collapse repeated whole words.
        s = s.replacingOccurrences(
            of: "\\b(\\w+)(\\s+\\1\\b)+",
            with: "$1",
            options: .regularExpression
        )

        // 5. Tidy spacing introduced by command/punctuation substitutions.
        s = tidySpacing(s)

        // 6. Capitalize first letter of each sentence.
        return capitalizeSentences(s)
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
