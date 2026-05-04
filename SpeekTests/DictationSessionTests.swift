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
    func insert(_ text: String) async throws { received = text }
}
