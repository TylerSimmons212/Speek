import Foundation

struct FormattingPipeline: Sendable {
    let rule: RuleStage
    let polish: any PolishStage

    func run(_ input: String) async -> String {
        let cleaned = rule.run(input)
        guard await polish.isAvailable else { return cleaned }
        return await polish.run(cleaned)
    }
}
