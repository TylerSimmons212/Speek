import FoundationModels
import Foundation

/// Field context handed to a polish stage: what already sits before the
/// cursor, split into read-only context and the rewriteable sentence fragment.
struct PolishContext: Sendable, Equatable {
    /// Earlier text — tone/reference only, must never appear in the output.
    var preceding: String
    /// The unfinished sentence immediately before the cursor.
    var fragment: String
}

struct PolishResult: Sendable, Equatable {
    var text: String
    /// True when `text` is the merged current sentence (fragment included,
    /// possibly corrected) rather than plain text to insert at the cursor.
    var mergedFragment: Bool
}

/// Abstraction over the polish stage so the pipeline can be tested with stubs.
/// FMPolishStage is the production implementation backed by Apple Foundation Models.
protocol PolishStage: Sendable, Actor {
    var isAvailable: Bool { get async }
    func run(_ input: String, context: PolishContext?) async -> PolishResult
}

/// LLM polish stage. Sends rule-cleaned text to the on-device 3B Foundation Models
/// model with a guided-generation rewrite prompt.
/// Skipped (returns input unchanged) when Apple Intelligence is unavailable.
actor FMPolishStage: PolishStage {
    @Generable
    struct PolishedTranscript {
        @Guide(description: "The cleaned-up version of the user's dictated text. Fix punctuation, casing, grammar, and remove filler words (um, uh). Critically: when the user self-corrects mid-sentence (phrases like \"I mean\", \"actually\", \"wait\", \"no, make that\", \"sorry\", \"scratch that\"), keep only the corrected version and drop the original mistaken phrase along with the correction marker.")
        let text: String
    }

    private let session: LanguageModelSession?

    init() {
        if SystemLanguageModel.default.isAvailable {
            self.session = LanguageModelSession(
                instructions: """
                You clean up voice-dictation transcripts. Produce only the final corrected text the user meant to write. Do not repeat the original transcript. Do not explain.

                Apply these rules:
                - When the speaker self-corrects ("I mean", "actually", "wait", "no, make that", "sorry", "scratch that"), drop the original phrasing and the correction marker, and keep only what came after the correction. For example, "lunch on Friday, actually Saturday" becomes "Lunch on Saturday."
                - Remove filler words: um, uh, like, you know.
                - Fix punctuation, capitalize sentence starts and proper nouns.
                - Do not rephrase, summarize, translate, or add content the speaker did not say.
                - If the transcript has no corrections or filler, just fix punctuation and capitalization.
                """
            )
        } else {
            self.session = nil
        }
    }

    var isAvailable: Bool { session != nil }

    /// Small on-device models occasionally echo the input verbatim before
    /// emitting the cleaned text. If we detect "<input><cleaned>" concatenation,
    /// keep only the cleaned trailing portion.
    fileprivate func trimEchoedInput(modelOutput: String, input: String) -> String {
        let trimmedOutput = modelOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty, trimmedOutput.count > trimmedInput.count else {
            return trimmedOutput
        }
        if trimmedOutput.hasPrefix(trimmedInput) {
            let tail = String(trimmedOutput.dropFirst(trimmedInput.count))
            let cleaned = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty {
                NSLog("FMPolishStage: stripped echoed input prefix from model output")
                return cleaned
            }
        }
        return trimmedOutput
    }

    /// Apple FM path ignores field context (its guided-generation prompt is
    /// fixed); it cleans the dictation standalone and never merges fragments.
    func run(_ input: String, context: PolishContext?) async -> PolishResult {
        PolishResult(text: await runPlain(input), mergedFragment: false)
    }

    private func runPlain(_ input: String) async -> String {
        guard !input.isEmpty else { return input }
        let enabled = await MainActor.run { SettingsStore.shared.polishEngine == .appleIntelligence }
        guard enabled else {
            NSLog("FMPolishStage: skipped — engine is not Apple Intelligence in Settings")
            return input
        }
        guard let session else {
            NSLog("FMPolishStage: skipped — SystemLanguageModel unavailable (Apple Intelligence not enabled?)")
            return input
        }
        NSLog("FMPolishStage: input → \(input)")
        do {
            let result = try await session.respond(
                to: "Clean up this dictated transcript:\n\n\(input)",
                generating: PolishedTranscript.self
            )
            let output = trimEchoedInput(modelOutput: result.content.text, input: input)
            NSLog("FMPolishStage: output → \(output)")
            return output
        } catch {
            NSLog("FMPolishStage: respond() threw \(error) — falling back to input unchanged")
            return input
        }
    }
}
