import AVFoundation
import FluidAudio
import Foundation

/// Kokoro-82M neural text-to-speech via FluidAudio's CoreML/ANE backend —
/// the same library that powers Speek's transcription. Fully on-device.
///
/// Long text is synthesized sentence-by-sentence (SentenceChunker) and
/// queued into an AVAudioPlayerNode, so playback starts after the first
/// sentence instead of after the whole passage. Buffer completions advance
/// the sentence highlight; synthesis stays a few sentences ahead of
/// playback and no further (backpressure), so stopping is instant and a
/// long article never balloons memory.
@MainActor
final class NeuralSpeechEngine {
    static let shared = NeuralSpeechEngine()

    /// Voice ids with this prefix route to the neural engine.
    nonisolated static let voiceIdentifierPrefix = "kokoro:"
    nonisolated static let defaultVoiceIdentifier = voiceIdentifierPrefix + KokoroAneConstants.defaultVoice

    private var manager: KokoroAneManager?
    private(set) var prepared = false

    private let audioEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connected = false

    private var synthesisTask: Task<Void, Never>?
    /// Bumped on every stop/speak; stale buffer completions compare against
    /// it and bail (player.stop() fires completions for flushed buffers).
    private var generation = 0
    private var chunkRanges: [NSRange] = []
    private var currentIndex = 0
    private var unplayed = 0
    private var synthesisComplete = false
    private var onChunkStart: ((Int) -> Void)?
    private var onFinished: (() -> Void)?

    /// Keep at most this many synthesized-but-unplayed sentences queued.
    private let maxQueuedBuffers = 3

    private init() {
        audioEngine.attach(player)
    }

    // MARK: - Model lifecycle

    /// Downloads the model on first call (~100 MB from Hugging Face, cached
    /// in ~/.cache/fluidaudio) and loads the 7-stage CoreML chain. First-ever
    /// load compiles for the Neural Engine and can take ~20s; warm loads are
    /// sub-second.
    func prepare() async throws {
        if prepared { return }
        let m: KokoroAneManager
        if let manager {
            m = manager
        } else {
            m = KokoroAneManager(variant: .english)
            manager = m
        }
        try await m.initialize()
        prepared = true
    }

    // MARK: - Voice packs

    /// Additional voice packs come from the standard Kokoro export (verified
    /// byte-identical format to the bundled af_heart). ~0.5 MB each, fetched
    /// once into the model cache; FluidAudio picks up local files first.
    private static let voicePackSource =
        "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/voices/"
    private static let voicePackByteCount = 510 * 256 * 4

    /// The English model's on-disk directory — located by finding the stock
    /// voice pack rather than hardcoding FluidAudio's cache layout.
    private static func voicePackDirectory() -> URL? {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/fluidaudio/Models")
        guard let enumerator = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: nil
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == "af_heart.bin" {
            return url.deletingLastPathComponent()
        }
        return nil
    }

    /// Downloads the pack if it isn't cached yet. No-op when present.
    /// Call only after prepare() — the model directory must exist.
    static func ensureVoiceDownloaded(_ pack: String) async throws {
        guard let dir = voicePackDirectory() else {
            throw NSError(domain: "NeuralSpeechEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Voice model not downloaded yet."
            ])
        }
        let destination = dir.appendingPathComponent("\(pack).bin")
        if FileManager.default.fileExists(atPath: destination.path) { return }
        guard let url = URL(string: voicePackSource + "\(pack).bin") else { return }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count == voicePackByteCount else {
            throw NSError(domain: "NeuralSpeechEngine", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Voice “\(pack)” isn't available upstream."
            ])
        }
        try data.write(to: destination, options: .atomic)
        NSLog("NeuralSpeechEngine: downloaded voice pack \(pack)")
    }

    // MARK: - Playback

    func speak(
        chunks: [SentenceChunker.Chunk],
        voice: String,
        speed: Float,
        onChunkStart: @escaping @MainActor (Int) -> Void,
        onFinished: @escaping @MainActor () -> Void,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        stop()
        guard let manager, prepared, !chunks.isEmpty else { return }
        generation += 1
        let gen = generation
        self.onChunkStart = onChunkStart
        self.onFinished = onFinished
        chunkRanges = chunks.map(\.range)
        currentIndex = 0
        unplayed = 0
        synthesisComplete = false

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(KokoroAneConstants.sampleRate),
            channels: 1,
            interleaved: false
        ) else { return }
        if !connected {
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: format)
            connected = true
        }
        do {
            if !audioEngine.isRunning { try audioEngine.start() }
        } catch {
            onError(error)
            return
        }
        player.play()
        onChunkStart(0)

        let texts = chunks.map(\.text)
        synthesisTask = Task { @MainActor [weak self] in
            for (index, text) in texts.enumerated() {
                guard let self, !Task.isCancelled, self.generation == gen else { return }
                // Backpressure: don't synthesize the whole article up front.
                while self.unplayed >= self.maxQueuedBuffers {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled, self.generation == gen else { return }
                }
                do {
                    let result = try await manager.synthesizeDetailed(text: text, voice: voice, speed: speed)
                    guard !Task.isCancelled, self.generation == gen else { return }
                    guard let buffer = Self.pcmBuffer(from: result.samples, format: format) else { continue }
                    self.unplayed += 1
                    self.player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                        Task { @MainActor [weak self] in self?.bufferPlayed(generation: gen) }
                    }
                } catch {
                    if self.generation == gen {
                        NSLog("NeuralSpeechEngine: synthesis failed at sentence \(index): \(error)")
                        onError(error)
                    }
                    return
                }
            }
            guard let self, self.generation == gen else { return }
            self.synthesisComplete = true
            self.finishIfDrained(generation: gen)
        }
    }

    func pause() {
        player.pause()
    }

    func resume() {
        guard audioEngine.isRunning else { return }
        player.play()
    }

    func stop() {
        synthesisTask?.cancel()
        synthesisTask = nil
        generation += 1
        onChunkStart = nil
        onFinished = nil
        player.stop()
        if audioEngine.isRunning { audioEngine.pause() }
        unplayed = 0
        currentIndex = 0
        chunkRanges = []
        synthesisComplete = false
    }

    // MARK: - Internals

    private func bufferPlayed(generation gen: Int) {
        guard gen == generation else { return }
        unplayed -= 1
        currentIndex += 1
        if currentIndex < chunkRanges.count {
            onChunkStart?(currentIndex)
        }
        finishIfDrained(generation: gen)
    }

    private func finishIfDrained(generation gen: Int) {
        guard gen == generation, synthesisComplete, unplayed <= 0 else { return }
        let finished = onFinished
        stop()
        finished?()
    }

    private static func pcmBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }
}
