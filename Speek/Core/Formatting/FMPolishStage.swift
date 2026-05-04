import FoundationModels
import Foundation

/// LLM polish stage. Sends rule-cleaned text to the on-device 3B Foundation Models
/// model with a guided-generation rewrite prompt.
/// Skipped (returns input unchanged) when Apple Intelligence is unavailable.
actor FMPolishStage {
    @Generable
    struct PolishedTranscript {
        @Guide(description: "The cleaned-up version of the user's dictated text. Preserve the user's intent. Fix punctuation, casing, and grammar. Do not add or remove substantive content.")
        let text: String
    }

    private let session: LanguageModelSession?

    init() {
        if SystemLanguageModel.default.isAvailable {
            self.session = LanguageModelSession(
                instructions: "You are a transcript-cleanup assistant. Given a dictated transcript, return only the cleaned text — no preamble, no commentary."
            )
        } else {
            self.session = nil
        }
    }

    var isAvailable: Bool { session != nil }

    func run(_ input: String) async -> String {
        guard !input.isEmpty, let session else { return input }
        do {
            let result = try await session.respond(
                to: "Clean up this dictated transcript:\n\n\(input)",
                generating: PolishedTranscript.self
            )
            return result.content.text
        } catch {
            return input
        }
    }
}
