import Foundation

/// Two-tier cleanup: a fast deterministic rule pass (custom vocabulary,
/// dictated punctuation commands), then s1-mini for everything language-
/// shaped — fillers, self-corrections, punctuation, casing, spoken numbers.
/// When the model isn't available (still downloading, disabled, or load
/// failure) the rule output ships as-is.
struct FormattingPipeline: Sendable {
    let rule: RuleStage
    let polish: any PolishStage

    func run(_ input: String) async -> String {
        let ruled = rule.run(input)
        guard !ruled.isEmpty, await polish.isAvailable else { return ruled }
        return await polish.run(ruled)
    }
}
