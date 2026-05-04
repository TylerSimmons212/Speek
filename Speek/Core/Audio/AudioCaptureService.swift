import AVFoundation

/// Captures mic input as 16kHz mono Float32 PCM frames.
/// Parakeet expects 16kHz mono input.
actor AudioCaptureService {
    enum CaptureError: Error { case engineFailed(Error), permissionDenied }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?

    /// Starts capture and returns an AsyncStream of Float32 PCM buffers.
    /// Each yielded chunk is ~100ms of audio at 16kHz (1600 samples).
    func start() throws -> AsyncStream<[Float]> {
        let stream = AsyncStream<[Float]> { continuation in
            self.continuation = continuation
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.engineFailed(NSError(domain: "speek", code: -1)) }

        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converter else { return }
            let frameCapacity = AVAudioFrameCount(targetFormat.sampleRate / 10) // ~100ms
            guard let outBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: frameCapacity
            ) else { return }

            var error: NSError?
            converter.convert(to: outBuffer, error: &error) { _, status in
                status.pointee = .haveData
                return buffer
            }
            guard error == nil,
                  let floats = outBuffer.floatChannelData?[0] else { return }
            let count = Int(outBuffer.frameLength)
            let samples = Array(UnsafeBufferPointer(start: floats, count: count))
            Task { await self.yield(samples) }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error)
        }
        return stream
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
        continuation = nil
    }

    private func yield(_ samples: [Float]) {
        continuation?.yield(samples)
    }
}
