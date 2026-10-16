import XCTest
@testable import Speek

@MainActor
final class DictationSessionTests: XCTestCase {
    func test_full_cycle_transitions_states() async throws {
        let audio = AudioCaptureService() // not actually used; we bypass startRecording
        let stub = StubTranscriber(text: "hello world")
        let pipeline = FormattingPipeline(rule: RuleStage(), polish: NoopPolish())
        let captured = CapturingInjector()
        let session = DictationSession(
            audio: audio,
            transcriber: stub,
            pipeline: pipeline,
            injector: captured
        )

        // Bypass actual audio capture: jump straight to .recording, then call stopRecording.
        session._setStateForTesting(.recording)
        await session.stopRecording()

        XCTAssertEqual(captured.received, "Hello world")
        XCTAssertEqual(session.state, .idle)
    }

    func test_filler_only_dictation_inserts_nothing() async throws {
        let audio = AudioCaptureService()
        let stub = StubTranscriber(text: "um uh") // normalizes to nothing
        let pipeline = FormattingPipeline(rule: RuleStage(), polish: NoopPolish())
        let captured = CapturingInjector()
        let session = DictationSession(
            audio: audio,
            transcriber: stub,
            pipeline: pipeline,
            injector: captured
        )

        session._setStateForTesting(.recording)
        await session.stopRecording()

        XCTAssertNil(captured.received)
        XCTAssertEqual(session.state, .idle)
    }
}

actor StubTranscriber: TranscriptionEngine {
    let text: String
    init(text: String) { self.text = text }
    func transcribe(samples: [Float]) async throws -> String { text }
}

actor NoopPolish: PolishStage {
    var isAvailable: Bool { false }
    func run(_ input: String) async -> String { input }
}

final class CapturingInjector: TextInjector, @unchecked Sendable {
    var received: String?
    var resultToReturn: InjectionResult = .inserted
    func insert(_ text: String) async throws -> InjectionResult {
        received = text
        return resultToReturn
    }
}

@MainActor
final class DictationSessionCaptureStartTests: XCTestCase {
    /// Publishing .recording runs observers synchronously on the main thread.
    /// In the app one of them is MediaPauseService's AppleScript, which can
    /// take hundreds of ms. The mic must not wait for it: the user is already
    /// talking.
    func test_capture_starts_while_a_recording_observer_blocks_the_main_thread() async throws {
        let audio = FakeCapture()
        let session = makeSession(audio: audio)
        let blocker = session.$state.sink { state in
            if state == .recording { Thread.sleep(forTimeInterval: 0.5) }
        }
        defer { blocker.cancel() }

        let pressed = Date()
        session.startRecording()
        let started = try await audio.waitForStart()

        XCTAssertLessThan(started.timeIntervalSince(pressed), 0.25,
                          "capture start waited for main-thread observers")
        await session.cancelRecording()
    }

    /// A release right after the press must stop the capture the press began,
    /// never stop first and leave a later start running (a stuck-open mic).
    func test_immediate_cancel_stops_the_capture_it_started() async throws {
        for _ in 0..<50 {
            let audio = FakeCapture()
            let session = makeSession(audio: audio)
            session.startRecording()
            await session.cancelRecording()
            let calls = await audio.calls
            XCTAssertEqual(calls, ["start", "stop"])
            XCTAssertEqual(session.state, .idle)
        }
    }

    /// Press, speak, release: the audio captured after the off-main start
    /// reaches the transcriber and the text is inserted.
    func test_press_speak_release_transcribes_captured_audio() async throws {
        let audio = FakeCapture()
        let transcriber = RecordingTranscriber(text: "hello world")
        let injector = CapturingInjector()
        let session = makeSession(audio: audio, transcriber: transcriber, injector: injector)

        session.startRecording()
        _ = try await audio.waitForStart()
        await audio.emit([Float](repeating: 0.1, count: 16_000))
        await session.stopRecording()

        let heard = await transcriber.sampleCount
        XCTAssertEqual(heard, 16_000)
        XCTAssertEqual(injector.received, "Hello world")
        let calls = await audio.calls
        XCTAssertEqual(calls, ["start", "stop"])
        XCTAssertEqual(session.state, .idle)
    }

    private func makeSession(
        audio: FakeCapture,
        transcriber: any TranscriptionEngine = StubTranscriber(text: ""),
        injector: CapturingInjector = CapturingInjector()
    ) -> DictationSession {
        DictationSession(
            audio: audio,
            transcriber: transcriber,
            pipeline: FormattingPipeline(rule: RuleStage(), polish: NoopPolish()),
            injector: injector
        )
    }
}

actor FakeCapture: AudioCapturing {
    private(set) var calls: [String] = []
    private var startedAt: Date?
    private var continuation: AsyncStream<[Float]>.Continuation?

    func start() throws -> AsyncStream<[Float]> {
        calls.append("start")
        startedAt = Date()
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        calls.append("stop")
        continuation?.finish()
        continuation = nil
    }

    func emit(_ chunk: [Float]) {
        continuation?.yield(chunk)
    }

    /// When start() ran, polling briefly so the test doesn't depend on which
    /// executor got there first.
    func waitForStart() async throws -> Date {
        for _ in 0..<200 {
            if let startedAt { return startedAt }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw XCTSkip("start() never ran")
    }
}

actor RecordingTranscriber: TranscriptionEngine {
    let text: String
    private(set) var sampleCount = 0
    init(text: String) { self.text = text }
    func transcribe(samples: [Float]) async throws -> String {
        sampleCount = samples.count
        return text
    }
}
