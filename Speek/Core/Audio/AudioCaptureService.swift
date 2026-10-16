import AVFoundation

/// Mic capture as DictationSession sees it: start yields 16 kHz mono chunks
/// until stop. AudioCaptureService in the app; a fake in tests.
protocol AudioCapturing: Actor {
    func start() throws -> AsyncStream<[Float]>
    func stop()
}

/// Captures mic input as 16kHz mono Float32 PCM frames.
/// Parakeet expects 16kHz mono input.
actor AudioCaptureService: AudioCapturing {
    enum CaptureError: Error { case engineFailed(Error), permissionDenied }

    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<[Float]>.Continuation?
    private var configChangeTask: Task<Void, Never>?

    /// Starts capture and returns an AsyncStream of Float32 PCM buffers.
    /// Each yielded chunk is one converted tap buffer (~21ms at a 48kHz
    /// native rate). Chunks are yielded directly from the tap callback, so
    /// ordering is FIFO and stop() leaves no chunks in flight.
    func start() throws -> AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        self.continuation = continuation
        try beginCapture(into: continuation)

        // Mic route changes mid-recording (AirPods connecting, a USB mic
        // unplugged) stop the engine and change the input format. Reinstall
        // the tap with a fresh converter so an in-flight dictation survives
        // the switch instead of going silently deaf. (The notification isn't
        // filtered by engine — Read Aloud owns another AVAudioEngine — but
        // reinstalling our tap is harmless when it fires for that one.)
        configChangeTask = Task { [weak self] in
            let changes = NotificationCenter.default
                .notifications(named: .AVAudioEngineConfigurationChange)
                .map { _ in () } // Notification itself isn't Sendable
            for await _ in changes {
                guard let self, !Task.isCancelled else { return }
                await self.restartAfterConfigChange()
            }
        }
        return stream
    }

    private func beginCapture(into continuation: AsyncStream<[Float]>.Continuation) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.engineFailed(NSError(domain: "speek", code: -1))
        }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            guard let samples = Self.convertedChunk(
                from: buffer,
                converter: converter,
                targetFormat: targetFormat
            ), !samples.isEmpty else { return }
            // AsyncStream continuations are thread-safe, and tap callbacks
            // for one node are serial — yielding here keeps chunks in order.
            continuation.yield(samples)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            throw CaptureError.engineFailed(error)
        }
    }

    private func restartAfterConfigChange() {
        guard let continuation else { return } // not capturing
        engine.inputNode.removeTap(onBus: 0)
        try? beginCapture(into: continuation)
    }

    /// Converts one tap buffer to the target format.
    ///
    /// The input block hands the converter this buffer EXACTLY ONCE and
    /// reports .noDataNow afterwards. Returning .haveData with the same
    /// buffer on every invocation — the obvious-looking implementation — is
    /// the classic AVAudioConverter bug: the converter keeps pulling until
    /// the output buffer is full and re-consumes the same input ~5x,
    /// feeding duplicated, stuttered audio downstream. The output buffer is
    /// sized for a single input buffer so nothing tempts the converter to
    /// ask for more.
    nonisolated static func convertedChunk(
        from buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> [Float]? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard capacity > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, let floats = outBuffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: floats, count: Int(outBuffer.frameLength)))
    }

    /// Stops capture. pause(), not stop(): the mic hardware stops (the
    /// privacy indicator goes off) but the engine keeps what prepare() set
    /// up, so the next press skips re-initializing the input unit.
    func stop() {
        configChangeTask?.cancel()
        configChangeTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.pause()
        continuation?.finish()
        continuation = nil
    }

    /// Builds the input node and prepares the engine without starting it, so
    /// the first press after launch doesn't pay for that setup (≈250–550 ms).
    /// Nothing is captured and the mic stays off. No-op while capturing.
    func prewarm() {
        guard continuation == nil,
              engine.inputNode.outputFormat(forBus: 0).sampleRate > 0 else { return }
        engine.prepare()
    }
}
