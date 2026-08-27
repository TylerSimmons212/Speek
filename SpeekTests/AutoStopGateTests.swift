import XCTest
@testable import Speek

final class AutoStopGateTests: XCTestCase {
    private let chunk: TimeInterval = 0.021 // ~one capture chunk

    private func feed(_ gate: inout AutoStopGate, rms: Float, seconds: TimeInterval) -> Bool {
        var stopped = false
        var elapsed: TimeInterval = 0
        while elapsed < seconds {
            if gate.observe(rms: rms, duration: chunk) { stopped = true }
            elapsed += chunk
        }
        return stopped
    }

    func test_silence_before_any_speech_never_stops() {
        var gate = AutoStopGate()
        // Latching then thinking for 10 seconds must not end the session.
        XCTAssertFalse(feed(&gate, rms: 0.01, seconds: 10))
    }

    func test_speech_then_pause_stops() {
        var gate = AutoStopGate()
        XCTAssertFalse(feed(&gate, rms: 0.5, seconds: 2))   // talking
        XCTAssertTrue(feed(&gate, rms: 0.01, seconds: 2))   // trailing pause
    }

    func test_brief_pause_mid_speech_does_not_stop() {
        var gate = AutoStopGate()
        XCTAssertFalse(feed(&gate, rms: 0.5, seconds: 2))
        XCTAssertFalse(feed(&gate, rms: 0.01, seconds: 0.8)) // breath, under hold
        XCTAssertFalse(feed(&gate, rms: 0.5, seconds: 1))    // resumes — pause reset
        XCTAssertFalse(feed(&gate, rms: 0.01, seconds: 1.0))
        XCTAssertTrue(feed(&gate, rms: 0.01, seconds: 1.0))  // now a real stop
    }

    func test_ambiguous_level_neither_extends_nor_resets_pause() {
        var gate = AutoStopGate()
        XCTAssertFalse(feed(&gate, rms: 0.5, seconds: 1))
        XCTAssertFalse(feed(&gate, rms: 0.01, seconds: 1.0)) // partial pause
        // Room tone between the thresholds: pause neither grows nor resets…
        XCTAssertFalse(feed(&gate, rms: 0.08, seconds: 5))
        // …so a little more true silence completes it.
        XCTAssertTrue(feed(&gate, rms: 0.01, seconds: 0.7))
    }

    func test_reset_clears_everything() {
        var gate = AutoStopGate()
        _ = feed(&gate, rms: 0.5, seconds: 2)
        gate.reset()
        XCTAssertFalse(feed(&gate, rms: 0.01, seconds: 3)) // no speech since reset
    }
}

final class PasteInjectorSnapshotTests: XCTestCase {
    func test_snapshot_and_restore_roundtrip() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("speek-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original contents", forType: .string)

        let saved = PasteInjector.snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("dictated text", forType: .string)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated text")

        pasteboard.clearContents()
        PasteInjector.restore(saved, to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "original contents")
    }

    func test_restore_of_empty_snapshot_is_noop() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("speek-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("something", forType: .string)
        PasteInjector.restore([], to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "something")
    }
}
