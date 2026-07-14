import Foundation

struct FormattingPipeline: Sendable {
    struct Output: Sendable {
        /// Text to hand the injector. In merged mode this is the whole
        /// corrected current sentence, not just the addition.
        let text: String
        /// True when `text` merged the field's unfinished fragment.
        let mergedFragment: Bool
        /// Regex-only formatting of the raw dictation — what the injector
        /// falls back to when a merged result can't be applied safely.
        let plainFallback: String
    }

    let rule: RuleStage
    let polish: any PolishStage
    /// `.whenNeeded` reserves the LLM for corrections the regex flagged as
    /// ambiguous (ships instantly otherwise). `.always` polishes every
    /// dictation — worthwhile with a fast local model.
    var mode: SettingsStore.PolishMode = .whenNeeded

    func run(_ input: String, context: PolishContext?) async -> Output {
        let result = rule.process(input)
        let wantsPolish: Bool
        switch mode {
        case .whenNeeded:
            // Field context makes the LLM meaningfully better than the regex
            // layer, so an unfinished fragment also justifies the polish hop.
            wantsPolish = result.possibleAmbiguousCorrection
                || !(context?.fragment.isEmpty ?? true)
        case .always:
            wantsPolish = true
        }
        guard wantsPolish, await polish.isAvailable else {
            return Output(text: result.text, mergedFragment: false, plainFallback: result.text)
        }
        let polished = await polish.run(result.text, context: context)
        return Output(
            text: polished.text,
            mergedFragment: polished.mergedFragment,
            plainFallback: result.text
        )
    }

    /// Context-free convenience, used by tests and any caller without a field
    /// snapshot.
    func run(_ input: String) async -> String {
        await run(input, context: nil).text
    }
}
