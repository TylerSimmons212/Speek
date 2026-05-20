import Combine
import Foundation

@MainActor
final class DictationSession: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case processing
        case inserting
        case copied
        case error(String)
    }

    @Published private(set) var state: State = .idle
    /// 0…1 RMS amplitude of the most recent audio chunk while recording.
    /// Drives the live level meter in the overlay pill.
    @Published private(set) var audioLevel: Float = 0

    private let audio: AudioCaptureService
    private let transcriber: any TranscriptionEngine
    /// Settable so the app can rebuild it (e.g. when the user edits their
    /// custom vocabulary in Settings) without recreating the session.
    var pipeline: FormattingPipeline
    private let injector: any TextInjector

    private var samples: [Float] = []
    private var captureTask: Task<Void, Never>?

    init(
        audio: AudioCaptureService,
        transcriber: any TranscriptionEngine,
        pipeline: FormattingPipeline,
        injector: any TextInjector
    ) {
        self.audio = audio
        self.transcriber = transcriber
        self.pipeline = pipeline
        self.injector = injector
    }

    func startRecording() {
        guard state == .idle else { return }
        // A new dictation supersedes any pending learn-from-correction watch.
        CorrectionLearner.shared.cancelPendingCheck()
        state = .recording
        samples = []
        audioLevel = 0
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.audio.start()
                for await chunk in stream {
                    let level = Self.rms(chunk)
                    await MainActor.run {
                        self.samples.append(contentsOf: chunk)
                        self.audioLevel = level
                    }
                }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
    }

    /// Root-mean-square amplitude of a PCM chunk, mapped roughly to 0…1 for
    /// driving a visual meter. Above ~0.3 RMS is already very loud speech.
    private static func rms(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        let mean = sum / Float(chunk.count)
        let raw = mean.squareRoot()
        // Scale so typical speech (RMS ~0.05-0.2) maps to a meaty 0.3-0.9.
        return min(1, raw * 4)
    }

    func stopRecording() async {
        guard state == .recording else { return }
        await audio.stop()
        captureTask?.cancel()
        state = .processing

        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let formatted = await pipeline.run(raw)
            state = .inserting
            let result = try await injector.insert(formatted)
            if result == .copied {
                // No editable target — show the user a "Copied" hint briefly
                // so they know to paste it themselves.
                state = .copied
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if state == .copied { state = .idle }
            } else {
                // Inserted in-place: watch for the user fixing a word so we can
                // auto-learn the corrected spelling.
                CorrectionLearner.shared.recordInsertion(insertedText: formatted)
                state = .idle
            }
        } catch {
            state = .error(error.localizedDescription)
            // Auto-clear after 2s
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .error = state { state = .idle }
        }
    }

    /// Aborts an in-flight recording without transcribing. Used for sub-threshold
    /// taps where the audio buffer is too short to be meaningful — avoids the
    /// "invalid audio data" path through Parakeet.
    func cancelRecording() async {
        guard state == .recording else { return }
        await audio.stop()
        captureTask?.cancel()
        samples = []
        state = .idle
    }

    #if DEBUG
    /// Test hook: forces state without going through startRecording().
    /// Used by DictationSessionTests to exercise stopRecording() in isolation.
    internal func _setStateForTesting(_ newState: State) {
        state = newState
    }
    #endif
}
