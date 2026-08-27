import AVFoundation
import XCTest
@testable import Speek

/// Regression tests for the AVAudioConverter input-block bug: returning the
/// same buffer with .haveData on every invocation makes the converter
/// re-consume the input ~5x per tap callback, feeding duplicated, stuttered
/// audio to the transcriber. Verified live before the fix: 1024 ramp frames
/// at 48kHz converted into 1600 output frames containing 14 ramp restarts.
final class AudioCaptureConversionTests: XCTestCase {
    private func makeBuffers(inputRate: Double, frames: AVAudioFrameCount)
    -> (AVAudioPCMBuffer, AVAudioConverter, AVAudioFormat) {
        let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate, channels: 1, interleaved: false
        )!
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = Float(i) / Float(frames) // monotonic ramp
        }
        return (buffer, AVAudioConverter(from: inFormat, to: outFormat)!, outFormat)
    }

    func test_48k_buffer_converts_once_without_duplication() {
        let (buffer, converter, outFormat) = makeBuffers(inputRate: 48_000, frames: 1024)
        let samples = AudioCaptureService.convertedChunk(
            from: buffer, converter: converter, targetFormat: outFormat
        )
        let out = try! XCTUnwrap(samples)

        // 1024 @ 48k → ~341 @ 16k. The buggy version produced 1600.
        XCTAssertGreaterThan(out.count, 250)
        XCTAssertLessThanOrEqual(out.count, 350)

        // A downsampled monotonic ramp stays monotonic; any significant
        // decrease means the input was consumed more than once.
        var restarts = 0
        for i in 1..<out.count where out[i] < out[i - 1] - 0.01 { restarts += 1 }
        XCTAssertEqual(restarts, 0, "duplicated input detected in converted audio")
    }

    func test_16k_native_buffer_passes_through_without_duplication() {
        let (buffer, converter, outFormat) = makeBuffers(inputRate: 16_000, frames: 1024)
        let out = try! XCTUnwrap(AudioCaptureService.convertedChunk(
            from: buffer, converter: converter, targetFormat: outFormat
        ))
        XCTAssertEqual(out.count, 1024)
        var restarts = 0
        for i in 1..<out.count where out[i] < out[i - 1] - 0.01 { restarts += 1 }
        XCTAssertEqual(restarts, 0)
    }

    func test_sequential_buffers_produce_continuous_stream() {
        // Feed two consecutive ramp segments; the converter (stateful) must
        // produce roughly one buffer's worth of output per call — never more.
        let inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false
        )!
        let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )!
        let converter = AVAudioConverter(from: inFormat, to: outFormat)!
        var total = 0
        for chunkIndex in 0..<10 {
            let buffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 1024)!
            buffer.frameLength = 1024
            for i in 0..<1024 {
                buffer.floatChannelData![0][i] = Float(chunkIndex * 1024 + i)
            }
            let out = AudioCaptureService.convertedChunk(
                from: buffer, converter: converter, targetFormat: outFormat
            ) ?? []
            total += out.count
        }
        // 10,240 input frames @48k ≈ 3,413 output frames @16k (± converter
        // priming). The buggy version produced ~16,000.
        XCTAssertGreaterThan(total, 3_000)
        XCTAssertLessThan(total, 3_800)
    }
}
