import AVFoundation
import Foundation
import Speech

/// Live-preview transcription via Apple's on-device SpeechAnalyzer
/// (macOS 26). Volatile hypotheses stream within a few hundred milliseconds
/// of speech, replacing the old 500ms whole-buffer Parakeet re-decode loop
/// for the overlay preview. PREVIEW ONLY — the final transcript is still
/// Parakeet's, which benchmarks better on English dictation-style speech.
///
/// Fails soft everywhere: when the locale is unsupported or the model asset
/// isn't installed yet, start() returns nil and DictationSession falls back
/// to the Parakeet preview loop.
actor SpeechPreviewEngine {
    static let shared = SpeechPreviewEngine()

    private var installed = false
    // Per-session state
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?

    /// Dictation's native chunk format (AudioCaptureService output).
    private let chunkFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
    )!

    private init() {}

    /// Ensures the on-device model for the user's locale is available
    /// (system-managed download via AssetInventory — no bundle cost).
    /// Called once at launch; safe to call repeatedly.
    func prepare() async {
        guard !installed else { return }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current),
              let transcriber = await makeTranscriber() else {
            NSLog("SpeechPreviewEngine: SpeechTranscriber unavailable for this locale")
            return
        }
        do {
            // Reserve keeps the locale's assets resident; the installation
            // request (nil when nothing needs downloading) fetches them.
            _ = try await AssetInventory.reserve(locale: locale)
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
            // .supported is sufficient in practice (verified live: the
            // analyzer starts and runs at .supported on a fresh machine) —
            // gating on .installed would wrongly disable the Apple tier.
            let status = await AssetInventory.status(forModules: [transcriber])
            installed = status >= .supported
            NSLog("SpeechPreviewEngine: asset status \(status), preview tier \(installed ? "enabled" : "disabled")")
        } catch {
            NSLog("SpeechPreviewEngine: asset preparation failed — \(error)")
        }
    }

    private func makeTranscriber() async -> SpeechTranscriber? {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            return nil
        }
        return SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            // volatileResults: instant low-confidence hypotheses that later
            // finalize — exactly what a live preview wants. fastResults
            // biases the engine toward latency over accuracy; fine here
            // because Parakeet owns the final text.
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: []
        )
    }

    /// Begins a preview session. Returns a stream of rolling display text
    /// (finalized prefix + latest volatile hypothesis), or nil when the
    /// Apple transcriber isn't usable — the caller falls back to Parakeet.
    func start() async -> AsyncStream<String>? {
        await finishCurrent() // never two sessions
        if !installed { await prepare() }
        guard installed, let transcriber = await makeTranscriber() else { return nil }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            return nil
        }
        converter = format == chunkFormat ? nil : AVAudioConverter(from: chunkFormat, to: format)
        analyzerFormat = format

        let (inputSequence, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        do {
            try await analyzer.start(inputSequence: inputSequence)
        } catch {
            NSLog("SpeechPreviewEngine: analyzer start failed — \(error)")
            inputContinuation.finish()
            return nil
        }
        self.analyzer = analyzer
        self.input = inputContinuation

        let (updates, updatesContinuation) = AsyncStream<String>.makeStream()
        resultsTask = Task {
            var finalized = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        updatesContinuation.yield(finalized)
                    } else {
                        updatesContinuation.yield(finalized + text)
                    }
                }
            } catch {
                // Analyzer torn down or errored — the preview simply stops;
                // dictation itself is unaffected.
            }
            updatesContinuation.finish()
        }
        return updates
    }

    /// Feeds one 16kHz mono chunk. No-op when no session is active.
    func feed(_ samples: [Float]) {
        guard let input, !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        if let converter, let analyzerFormat {
            guard let converted = Self.convert(buffer, with: converter, to: analyzerFormat) else { return }
            input.yield(AnalyzerInput(buffer: converted))
        } else {
            input.yield(AnalyzerInput(buffer: buffer))
        }
    }

    /// One-shot input block — same discipline as AudioCaptureService: never
    /// let the converter re-pull (and duplicate) the same buffer.
    private static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 8
        guard capacity > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            return nil
        }
        var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }

    /// Ends the current session (if any) and tears down the analyzer.
    func finish() async {
        await finishCurrent()
    }

    private func finishCurrent() async {
        guard analyzer != nil || input != nil else { return }
        input?.finish()
        input = nil
        await analyzer?.cancelAndFinishNow()
        analyzer = nil
        resultsTask?.cancel()
        resultsTask = nil
        converter = nil
        analyzerFormat = nil
    }
}
