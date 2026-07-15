import XCTest
@testable import Speek

final class SilenceGateChunkerTests: XCTestCase {

    func test_no_flush_below_min_window() {
        var gate = SilenceGateChunker()
        gate.observe(rms: 0.001, duration: 1.0) // silence
        XCTAssertFalse(gate.shouldFlush(windowDuration: 1.0))
    }

    func test_flush_after_speech_then_pause() {
        var gate = SilenceGateChunker()
        gate.observe(rms: 0.1, duration: 3.0)   // speech
        XCTAssertFalse(gate.shouldFlush(windowDuration: 3.0))
        gate.observe(rms: 0.001, duration: 0.9) // pause
        XCTAssertTrue(gate.shouldFlush(windowDuration: 3.9))
    }

    func test_speech_resets_silence_run() {
        var gate = SilenceGateChunker()
        gate.observe(rms: 0.001, duration: 0.5)
        gate.observe(rms: 0.1, duration: 0.5)   // speech resumes
        gate.observe(rms: 0.001, duration: 0.5) // not yet 0.8s of silence
        XCTAssertFalse(gate.shouldFlush(windowDuration: 5.0))
    }

    func test_hard_cap_flushes_mid_speech() {
        var gate = SilenceGateChunker()
        gate.observe(rms: 0.2, duration: 15.0)  // continuous speech
        XCTAssertTrue(gate.shouldFlush(windowDuration: 15.0))
    }

    func test_reset_clears_run() {
        var gate = SilenceGateChunker()
        gate.observe(rms: 0.001, duration: 2.0)
        gate.reset()
        XCTAssertFalse(gate.shouldFlush(windowDuration: 3.0))
    }

    func test_resample_48k_to_16k_averages_triples() {
        let samples: [Float] = [3, 3, 3, 6, 6, 6, 9, 9, 9]
        let out = SystemAudioTapService.resampleTo16k(samples, fromRate: 48_000)
        XCTAssertEqual(out, [3, 6, 9])
    }

    func test_resample_16k_passthrough() {
        let samples: [Float] = [1, 2, 3]
        XCTAssertEqual(SystemAudioTapService.resampleTo16k(samples, fromRate: 16_000), samples)
    }

    func test_resample_44100_produces_expected_count() {
        let samples = [Float](repeating: 0.5, count: 44_100) // 1 second
        let out = SystemAudioTapService.resampleTo16k(samples, fromRate: 44_100)
        // ~16000 samples, allow converter edge slack.
        XCTAssertGreaterThan(out.count, 15_800)
        XCTAssertLessThanOrEqual(out.count, 16_100)
    }
}
