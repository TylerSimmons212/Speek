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
    private let livePreview = SpeechPreviewEngine.shared
    private let transcriber: any TranscriptionEngine
    /// Settable so the app can rebuild it (e.g. when the user edits their
    /// custom vocabulary in Settings) without recreating the session.
    var pipeline: FormattingPipeline
    private let injector: any TextInjector

    private var samples: [Float] = []
    private var captureTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    /// True while a latched (toggle) recording should end itself after a
    /// trailing pause. Armed by the app layer on double-tap latch; held
    /// push-to-talk never auto-stops.
    private var autoStopArmed = false
    private var autoStopGate = AutoStopGate()
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
        autoStopArmed = false
        autoStopGate.reset()
        if SettingsStore.shared.livePreviewEnabled {
            startPreview()
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
                    // No-op unless an Apple preview session is active.
                    await self.livePreview.feed(chunk)
                    if self.autoStopArmed,
                       self.autoStopGate.observe(rms: level, duration: Double(chunk.count) / 16_000) {
                        self.autoStopArmed = false
                        Task { await self.stopRecording() }
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

    /// Two-tier live preview. Primary: Apple's SpeechAnalyzer streams
    /// volatile hypotheses within a few hundred ms of speech (fed chunk by
    /// chunk from the capture loop). Fallback (assets missing, locale
    /// unsupported): the Parakeet re-decode loop. Either way the preview is
    /// purely cosmetic — the final transcript always comes from the full
    /// pipeline in stopRecording().
    private func startPreview() {
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            guard let self else { return }
            if let updates = await self.livePreview.start() {
                for await text in updates {
                    guard !Task.isCancelled, self.state == .recording else { break }
                    if !text.isEmpty { self.partialText = text }
                }
            } else {
                await self.runParakeetPreviewLoop()
            }
        }
    }

    /// Fallback preview: re-transcribes the accumulated buffer on a fixed
    /// cadence and publishes a flicker-stable rolling transcript. AsrManager
    /// is an actor, so these decodes and the final decode in stopRecording()
    /// serialize safely; a slow decode naturally stretches the cadence.
    private func runParakeetPreviewLoop() async {
        let intervalNs = UInt64(previewInterval * 1_000_000_000)
        var merger = PartialTranscriptMerger()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: intervalNs)
            guard !Task.isCancelled, state == .recording else { return }
            let snapshot = samples
            guard snapshot.count >= previewMinSamples else { continue }
            // Preview failures are non-events — skip the tick and let the
            // next one try again.
            guard let text = try? await transcriber.transcribePreview(samples: snapshot) else { continue }
            guard !Task.isCancelled, state == .recording else { return }
            let display = merger.merge(text)
            if !display.isEmpty { partialText = display }
        }
    }

    func stopRecording() async {
        guard state == .recording else { return }
        await audio.stop()
        previewTask?.cancel()
        previewTask = nil
        await livePreview.finish()
        // Drain the capture loop instead of cancelling it: audio.stop()
        // finished the stream, but the last chunks may still be between the
        // tap and `samples` — cancelling here could drop the tail of the
        // utterance (the classic "last word cut off").
        await captureTask?.value
        captureTask = nil
        state = .processing

        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let text = await pipeline.run(raw)
            partialText = ""
            guard !text.isEmpty else {
                // A filler-only dictation legitimately normalizes to nothing.
                state = .idle
                return
            }
            state = .inserting
            let result = try await injector.insert(text)
            if result == .copied {
                // No editable target — show the user a "Copied" hint briefly
                // so they know to paste it themselves.
                state = .copied
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                if state == .copied { state = .idle }
            } else {
                // Inserted in-place: watch for the user fixing a word so we can
                // auto-learn the corrected spelling.
                CorrectionLearner.shared.recordInsertion(insertedText: text)
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

    /// Arms hands-free auto-stop for the current latched recording: after
    /// speech followed by a trailing pause, the session stops itself. The
    /// app layer calls this on double-tap latch when the setting is on.
    func armAutoStop() {
        guard state == .recording else { return }
        autoStopGate.reset()
        autoStopArmed = true
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
        await livePreview.finish()
        samples = []
        partialText = ""
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
