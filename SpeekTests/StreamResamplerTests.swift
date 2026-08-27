import XCTest
@testable import Speek

final class StreamResamplerTests: XCTestCase {
    func test_16k_input_passes_through() {
        let resampler = StreamResampler(fromRate: 16_000)
        let input: [Float] = (0..<1000).map { Float($0) }
        XCTAssertEqual(resampler.resample(input), input)
    }

    func test_44k_stream_is_continuous_across_chunk_boundaries() {
        // A monotonic ramp fed in 10 chunks must stay monotonic in the
        // output. The old per-drain converter re-primed with silence at
        // every chunk boundary, producing dips/restarts there.
        let resampler = StreamResampler(fromRate: 44_100)
        var output: [Float] = []
        let chunkSize = 4_410 // 100ms
        for chunk in 0..<10 {
            let samples = (0..<chunkSize).map { Float(chunk * chunkSize + $0) }
            output.append(contentsOf: resampler.resample(samples))
        }
        // ~44,100 in @44.1k → ~16,000 out @16k (± converter priming).
        XCTAssertGreaterThan(output.count, 14_000)
        XCTAssertLessThan(output.count, 16_500)

        // Skip the converter's priming ramp-in, then demand monotonicity —
        // discontinuities at chunk boundaries would show as decreases.
        var violations = 0
        for i in 200..<output.count where output[i] < output[i - 1] - 1.0 { violations += 1 }
        XCTAssertEqual(violations, 0, "discontinuity at a chunk boundary")
    }

    func test_48k_total_sample_count_has_no_cumulative_drift() {
        let resampler = StreamResampler(fromRate: 48_000)
        var total = 0
        for _ in 0..<50 {
            total += resampler.resample([Float](repeating: 0.5, count: 4_800)).count
        }
        // 50 × 100ms = 5s → 80,000 samples @16k. The old path truncated
        // fractional samples per chunk and lost them permanently.
        XCTAssertGreaterThan(total, 79_000)
        XCTAssertLessThanOrEqual(total, 80_050)
    }
}
