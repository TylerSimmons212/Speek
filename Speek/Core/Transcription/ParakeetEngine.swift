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
final class ParakeetEngine: TranscriptionEngine {
    enum EngineError: Error {
        case modelNotReady
    }

    private let manager: AsrManager
    private let decoderLayers: Int

    init() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount
    }

    func transcribe(samples: [Float]) async throws -> String {
        try await transcribeWithWordTimings(samples: samples).text
    }

    /// Word timings come from the TDT decoder's token timings (encoder
    /// frames, 80 ms), grouped into words on SentencePiece boundaries —
    /// the same grouping that turns tokens into `text`.
    func transcribeWithWordTimings(samples: [Float]) async throws -> TimedTranscript {
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            TimedTranscript.Word(start: $0.startTime, end: $0.endTime)
        }
        return TimedTranscript(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            decodedWords: words
        )
    }
}
