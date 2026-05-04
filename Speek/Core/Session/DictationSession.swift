import Combine
import Foundation

@MainActor
final class DictationSession: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case processing
        case inserting
        case error(String)
    }

    @Published private(set) var state: State = .idle

    private let audio: AudioCaptureService
    private let transcriber: any TranscriptionEngine
    private let pipeline: FormattingPipeline
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
        state = .recording
        samples = []
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.audio.start()
                for await chunk in stream {
                    await MainActor.run { self.samples.append(contentsOf: chunk) }
                }
            } catch {
                await MainActor.run { self.state = .error(error.localizedDescription) }
            }
        }
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
            try await injector.insert(formatted)
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
            // Auto-clear after 2s
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if case .error = state { state = .idle }
        }
    }

    #if DEBUG
    /// Test hook: forces state without going through startRecording().
    /// Used by DictationSessionTests to exercise stopRecording() in isolation.
    internal func _setStateForTesting(_ newState: State) {
        state = newState
    }
    #endif
}
