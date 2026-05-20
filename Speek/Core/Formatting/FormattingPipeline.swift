import Foundation

struct FormattingPipeline: Sendable {
    let rule: RuleStage
    let polish: any PolishStage

    func run(_ input: String) async -> String {
        let result = rule.process(input)
        // The LLM polish stage is reserved for cases the regex couldn't resolve.
        // No correction markers, or a clean substitution → ship instantly.
        // Only ambiguous markers fall through to the slower LLM.
        guard result.possibleAmbiguousCorrection, await polish.isAvailable else {
            return result.text
        }
        return await polish.run(result.text)
    }
}
