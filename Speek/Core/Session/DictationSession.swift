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
    /// Rolling transcript of the current recording, updated every preview
    /// tick. Empty when live preview is disabled or nothing decoded yet.
    @Published private(set) var partialText: String = ""

    private let audio: AudioCaptureService
    private let transcriber: any TranscriptionEngine
    /// Settable so the app can rebuild it (e.g. when the user edits their
    /// custom vocabulary in Settings) without recreating the session.
    var pipeline: FormattingPipeline
    private let injector: any TextInjector

    private var samples: [Float] = []
    private var captureTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// Focused-field snapshot taken at recording start — feeds field context
    /// into the pipeline and enables in-place seam repair at insertion.
    private var fieldSnapshot: FieldSnapshot?
    /// Seconds between live-preview decodes. Each tick re-transcribes the
    /// whole buffer; on the ANE this is fast enough that a fixed cadence
    /// works, and because the decode happens inline in the loop, a slow
    /// decode naturally stretches the effective interval (built-in
    /// backpressure — ticks are never stacked).
    private let previewInterval: TimeInterval = 0.5
    /// Don't bother decoding less than this much audio (0.5s @ 16kHz) —
    /// sub-half-second buffers waste a decode on silence or half a phoneme.
    private let previewMinSamples = 8000

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
        partialText = ""
        // Snapshot the focused field NOW — this is where the user's caret is;
        // by insertion time the pipeline needs to have formatted against it.
        fieldSnapshot = FieldContextReader.capture()
        if SettingsStore.shared.livePreviewEnabled {
            startPreviewLoop()
        }
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

    /// Re-transcribes the accumulated buffer on a fixed cadence and publishes
    /// a flicker-stable rolling transcript. Runs only while recording; the
    /// final transcript still comes from the full pipeline in stopRecording()
    /// — this loop is purely cosmetic feedback.
    private func startPreviewLoop() {
        previewTask?.cancel()
        let intervalNs = UInt64(previewInterval * 1_000_000_000)
        let minSamples = previewMinSamples
        previewTask = Task { [weak self] in
            var merger = PartialTranscriptMerger()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: intervalNs)
                guard let self, !Task.isCancelled else { return }
                guard self.state == .recording else { return }
                let snapshot = self.samples
                guard snapshot.count >= minSamples else { continue }
                // Preview failures are non-events — skip the tick and let the
                // next one try again. AsrManager is an actor, so this decode
                // and the final decode in stopRecording() serialize safely.
                guard let text = try? await self.transcriber.transcribe(samples: snapshot) else { continue }
                guard !Task.isCancelled, self.state == .recording else { return }
                let display = merger.merge(text)
                if !display.isEmpty { self.partialText = display }
            }
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        await audio.stop()
        captureTask?.cancel()
        previewTask?.cancel()
        previewTask = nil
        state = .processing

        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let output = await pipeline.run(raw, context: fieldSnapshot?.polishContext)
            partialText = ""
            state = .inserting
            let result: InjectionResult
            if let contextInjector = injector as? ContextAwareInjector {
                result = try await contextInjector.insert(output, snapshot: fieldSnapshot)
            } else {
                result = try await injector.insert(output.text)
            }
            fieldSnapshot = nil
            if result == .copied {
                // No editable target — show the user a "Copied" hint briefly
                // so they know to paste it themselves.
                state = .copied
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if state == .copied { state = .idle }
            } else {
                // Inserted in-place: watch for the user fixing a word so we can
                // auto-learn the corrected spelling.
                CorrectionLearner.shared.recordInsertion(insertedText: output.text)
                state = .idle
            }
        } catch {
            partialText = ""
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
        previewTask?.cancel()
        previewTask = nil
        samples = []
        partialText = ""
        fieldSnapshot = nil
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
