import XCTest
@testable import Speek

final class EchoReferenceAlignerTests: XCTestCase {
    private let tick = 8_000 // one 500 ms meeting-pump drain at 16 kHz

    private func ramp(_ count: Int, from start: Int) -> [Float] {
        (0..<count).map { Float(start + $0) }
    }

    func test_pairs_are_always_equal_length() {
        var aligner = EchoReferenceAligner()
        for (m, r) in [(8_000, 8_000), (0, 8_000), (8_000, 0), (7_990, 8_013), (336, 0)] {
            let out = aligner.push(mic: [Float](repeating: 1, count: m), reference: [Float](repeating: 1, count: r))
            XCTAssertEqual(out.mic.count, out.reference.count)
        }
    }

    func test_mic_is_held_one_prefill_behind_the_reference() {
        var aligner = EchoReferenceAligner()
        let mic = ramp(tick, from: 1)
        let reference = ramp(tick, from: 100_000)
        let out = aligner.push(mic: mic, reference: reference)

        XCTAssertEqual(out.reference, reference, "reference passes straight through")
        XCTAssertEqual(Array(out.mic.prefix(aligner.prefill)), [Float](repeating: 0, count: aligner.prefill))
        XCTAssertEqual(Array(out.mic.dropFirst(aligner.prefill)), Array(mic.prefix(tick - aligner.prefill)))
        XCTAssertEqual(aligner.skew, aligner.targetSkew)
        XCTAssertEqual(aligner.corrections, 0)
    }

    func test_reference_captured_before_the_mic_starts_is_skipped() {
        // The tap is up a tick before the mic engine delivers anything.
        var aligner = EchoReferenceAligner()
        let early = aligner.push(mic: [], reference: [Float](repeating: 9, count: tick))
        XCTAssertTrue(early.mic.isEmpty)

        let out = aligner.push(mic: [Float](repeating: 2, count: tick), reference: [Float](repeating: 3, count: tick))
        XCTAssertFalse(out.reference.contains(9), "pre-mic reference never pairs with mic audio")
        XCTAssertEqual(out.reference.count, tick)
        XCTAssertEqual(aligner.skew, aligner.targetSkew)
    }

    func test_tap_stall_pads_the_reference_with_silence() {
        var aligner = EchoReferenceAligner()
        _ = aligner.push(mic: [Float](repeating: 1, count: tick), reference: [Float](repeating: 1, count: tick))
        // Tap delivers nothing for a tick; the mic keeps going.
        let out = aligner.push(mic: [Float](repeating: 1, count: tick), reference: [])
        XCTAssertEqual(out.mic.count, tick, "the mic isn't held hostage by a stalled reference")
        XCTAssertEqual(out.reference, [Float](repeating: 0, count: tick))
        XCTAssertEqual(aligner.skew, aligner.targetSkew)
    }

    func test_clock_drift_stays_inside_the_window_with_rare_corrections() {
        // Mic clock 0.2% fast, then 0.2% slow, for ~8 minutes each.
        var aligner = EchoReferenceAligner()
        for _ in 0..<1_000 {
            _ = aligner.push(mic: [Float](repeating: 0, count: 8_016), reference: [Float](repeating: 0, count: tick))
            XCTAssertLessThanOrEqual(aligner.skew, aligner.highWater)
        }
        for _ in 0..<1_000 {
            _ = aligner.push(mic: [Float](repeating: 0, count: 7_984), reference: [Float](repeating: 0, count: tick))
            XCTAssertGreaterThanOrEqual(aligner.skew, aligner.lowWater)
        }
        // 16 samples/tick of drift crosses a ~3,200-sample margin every ~200 ticks.
        XCTAssertLessThan(aligner.corrections, 20)
        XCTAssertGreaterThan(aligner.corrections, 0)
    }

    func test_every_mic_sample_comes_out_once_and_in_order() {
        var aligner = EchoReferenceAligner()
        var next = 1
        var output: [Float] = []
        // Uneven, drifting, stalling deliveries.
        let pattern = [(8_000, 8_000), (0, 8_000), (8_100, 7_900), (8_000, 0), (5_000, 9_000), (8_000, 8_000)]
        for (m, r) in pattern {
            let mic = ramp(m, from: next)
            next += m
            output += aligner.push(mic: mic, reference: [Float](repeating: 0, count: r)).mic
        }
        let tail = aligner.drain()
        XCTAssertEqual(tail.mic.count, tail.reference.count)
        output += tail.mic

        let real = Array(output.dropFirst(aligner.prefill))
        XCTAssertEqual(Array(output.prefix(aligner.prefill)), [Float](repeating: 0, count: aligner.prefill))
        XCTAssertEqual(real, ramp(next - 1, from: 1))
    }
}
