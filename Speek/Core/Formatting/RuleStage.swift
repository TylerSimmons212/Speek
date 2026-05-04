import Foundation

/// Deterministic, fast (<10ms) cleanup pass.
/// - Strips filler words (um, uh, like, you know).
/// - Collapses immediately-repeated words.
/// - Capitalizes sentence starts.
/// - Applies user-defined custom replacements (case-insensitive match, case-aware replacement).
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

        // 2. Strip fillers (whole-word, case-insensitive).
        let fillerPattern = "\\b(\(fillers.joined(separator: "|")))\\b"
        s = s.replacingOccurrences(
            of: fillerPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )

        // 3. Collapse repeated whole words.
        s = s.replacingOccurrences(
            of: "\\b(\\w+)(\\s+\\1\\b)+",
            with: "$1",
            options: .regularExpression
        )

        // 4. Collapse multiple whitespace.
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // 5. Capitalize first letter of each sentence.
        s = capitalizeSentences(s)
        return s
    }

    private func capitalizeSentences(_ input: String) -> String {
        var chars = Array(input)
        var capitalizeNext = true
        for i in chars.indices {
            let c = chars[i]
            if capitalizeNext, c.isLetter {
                chars[i] = Character(c.uppercased())
                capitalizeNext = false
            } else if c == "." || c == "!" || c == "?" {
                capitalizeNext = true
            } else if !c.isWhitespace {
                capitalizeNext = false
            }
        }
        return String(chars)
    }
}
