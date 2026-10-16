import FluidAudio
import Foundation

/// FluidAudio-backed transcription engine using the Parakeet TDT v2 model
/// (English-only — slightly better English recall than v3 multilingual per
/// FluidAudio docs, and Speek is English-only for v1).
///
/// The plan's draft assumed an `AsrPipeline` type with a one-shot
/// `transcribe(samples:sampleRate:)` entry point. The actual FluidAudio API
/// uses an `AsrManager` actor that requires:
///   1. Downloading + loading `AsrModels` separately
///   2. Calling `AsrManager.loadModels(_:)` to wire models into the manager
///   3. Calling `transcribe(_ audioSamples:[Float], decoderState: inout TdtDecoderState, language: Language?)`
///      which returns an `ASRResult` (sample rate is fixed at 16kHz internally)
///
/// We use a fresh `TdtDecoderState` per call because Speek transcribes whole
/// utterances in batch (Fn release → full buffer → text) — there's no
/// streaming continuity to preserve across calls.
///
/// Custom vocabulary is applied acoustically: when the user has boostable
/// terms, `transcribe` rescores the TDT transcript against a separate CTC
/// encoder's log-probs (FluidAudio's `VocabularyBoostingSession`, the stable
/// "Approach 2" for TDT v2, which has no CTC head). RuleStage's string
/// replacement still runs afterwards as the exact-match second pass.
final class ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error {
        case modelNotReady
    }

    private let manager: AsrManager
    private let decoderLayers: Int
    let vocabulary = VocabularyBooster()

    init() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount
    }

    /// Final decode: TDT, then vocabulary rescoring when boosting is active
    /// and the transcript has a span close enough to a term to be rescored.
    func transcribe(samples: [Float]) async throws -> String {
        let result = try await decode(samples)
        guard let boost = await vocabulary.active(),
              let timings = result.tokenTimings, !timings.isEmpty,
              boost.policy.hasCandidate(in: result.text),
              let rescored = await boost.session.rescore(
                  text: result.text, tokenTimings: timings, audioSamples: samples
              )
        else { return Self.clean(result.text) }

        let applied = rescored.replacements.compactMap { r in
            r.shouldReplace
                ? r.replacementWord.map { VocabularyRescorePolicy.Replacement(span: r.originalWord, term: $0) }
                : nil
        }
        guard !applied.isEmpty else { return Self.clean(result.text) }
        let text = boost.policy.splice(applied, into: result.text)
        NSLog("ParakeetEngine: vocabulary rescoring applied \(applied.map { "'\($0.span)' → '\($0.term)'" })")
        return Self.clean(text)
    }

    /// Preview decode: TDT only. Live previews re-decode the growing buffer
    /// every tick, so they skip the CTC pass; the final decode applies it.
    func transcribePreview(samples: [Float]) async throws -> String {
        Self.clean(try await decode(samples).text)
    }

    private func decode(_ samples: [Float]) async throws -> ASRResult {
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        return try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
