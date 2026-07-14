import Foundation

struct FormattingPipeline: Sendable {
    let rule: RuleStage
    let polish: any PolishStage
    /// `.whenNeeded` reserves the LLM for corrections the regex flagged as
    /// ambiguous (ships instantly otherwise). `.always` polishes every
    /// dictation — worthwhile with a fast local model.
    var mode: SettingsStore.PolishMode = .whenNeeded

    func run(_ input: String) async -> String {
        let result = rule.process(input)
        let wantsPolish: Bool
        switch mode {
        case .whenNeeded: wantsPolish = result.possibleAmbiguousCorrection
        case .always: wantsPolish = true
        }
        guard wantsPolish, await polish.isAvailable else {
            return result.text
        }
        return await polish.run(result.text)
    }
}
