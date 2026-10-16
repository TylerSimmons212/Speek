import Foundation

/// Two-tier cleanup: a fast deterministic rule pass (custom vocabulary,
/// dictated punctuation commands), then s1-mini for everything language-
/// shaped — fillers, self-corrections, punctuation, casing, spoken numbers.
/// When the model isn't available (still downloading, disabled, or load
/// failure) the rule output ships as-is.
struct FormattingPipeline: Sendable {
    let rule: RuleStage
    let polish: any PolishStage

    /// `style` shapes the polish pass only (register, lists, email layout);
    /// the rule pass is style-independent.
    func run(_ input: String, style: PolishStyle = .standard) async -> String {
        let ruled = rule.run(input)
        guard !ruled.isEmpty, await polish.isAvailable else { return ruled }
        return await polish.run(ruled, style: style)
    }
}
