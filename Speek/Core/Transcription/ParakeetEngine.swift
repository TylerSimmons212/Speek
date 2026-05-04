import FluidAudio
import Foundation

/// FluidAudio-backed transcription engine using the Parakeet TDT v3 model.
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
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        self.decoderLayers = await manager.decoderLayerCount
    }

    func transcribe(samples: [Float]) async throws -> String {
        var decoderState = try TdtDecoderState(decoderLayers: decoderLayers)
        let result = try await manager.transcribe(samples, decoderState: &decoderState, language: nil)
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
