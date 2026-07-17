import AVFoundation
import Combine
import Foundation

/// On-device text-to-speech via AVSpeechSynthesizer. Speaks with the user's
/// chosen system voice (or the best installed Premium/Enhanced voice for
/// their locale), publishes the word currently being spoken so the overlay
/// can render a karaoke-style highlight, and exposes simple transport
/// controls (pause/resume/stop).
@MainActor
final class SpeechService: NSObject, ObservableObject {
    static let shared = SpeechService()

    enum State: Equatable {
        case idle
        /// Neural engine warming up: model download on first use (~100 MB)
        /// or CoreML load. Cancellable via stop().
        case preparing
        case speaking(paused: Bool)
    }

    @Published private(set) var state: State = .idle
    /// The full text of the current utterance.
    @Published private(set) var currentText: String = ""
    /// UTF-16 range of the word being spoken, in `currentText` coordinates.
    @Published private(set) var spokenRange: NSRange?

    private let synthesizer = AVSpeechSynthesizer()
    /// Identity of the utterance we're currently speaking — delegate events
    /// for anything else (a stopped utterance's trailing didCancel) are stale
    /// and ignored.
    private var currentUtteranceID: ObjectIdentifier?
    /// True while the neural (Kokoro) engine owns playback.
    private var neuralActive = false
    private var neuralTask: Task<Void, Never>?
    /// The sentence chunks of the current neural read — kept for the
    /// Apple-voice fallback (resume from the failing sentence).
    private var neuralChunks: [SentenceChunker.Chunk] = []
    private var neuralChunkIndex = 0

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { state != .idle }

    /// 0…1 fraction of the text spoken so far (drives the progress ring/bar).
    var progress: Double {
        let total = (currentText as NSString).length
        guard total > 0, let r = spokenRange, r.location != NSNotFound else { return 0 }
        return min(1, Double(r.location + r.length) / Double(total))
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()

        if SettingsStore.shared.ttsVoiceIdentifier.hasPrefix(NeuralSpeechEngine.voiceIdentifierPrefix) {
            speakNeural(trimmed)
        } else {
            speakApple(trimmed, voiceIdentifier: SettingsStore.shared.ttsVoiceIdentifier)
        }
    }

    func pauseOrResume() {
        guard case .speaking(let paused) = state else { return }
        if neuralActive {
            paused ? NeuralSpeechEngine.shared.resume() : NeuralSpeechEngine.shared.pause()
        } else if paused {
            synthesizer.continueSpeaking()
        } else {
            synthesizer.pauseSpeaking(at: .word)
        }
        state = .speaking(paused: !paused)
    }

    func stop() {
        neuralTask?.cancel()
        neuralTask = nil
        if neuralActive || state == .preparing {
            NeuralSpeechEngine.shared.stop()
        }
        neuralActive = false
        neuralChunks = []
        neuralChunkIndex = 0
        if currentUtteranceID != nil {
            // Clear identity FIRST: stopSpeaking delivers didCancel, which
            // must not clobber the state of a new utterance started after.
            currentUtteranceID = nil
            synthesizer.stopSpeaking(at: .immediate)
        }
        state = .idle
        spokenRange = nil
    }

    // MARK: - Apple engine

    private func speakApple(_ text: String, voiceIdentifier: String) {
        currentText = text
        spokenRange = nil
        let utterance = AVSpeechUtterance(string: text)
        if let voice = Self.resolveVoice(preferredIdentifier: voiceIdentifier) {
            utterance.voice = voice
        }
        utterance.rate = Float(SettingsStore.shared.ttsRate)
        currentUtteranceID = ObjectIdentifier(utterance)
        state = .speaking(paused: false)
        synthesizer.speak(utterance)
    }

    // MARK: - Neural engine (Kokoro via FluidAudio)

    private func speakNeural(_ text: String) {
        let chunks = SentenceChunker.split(text)
        guard !chunks.isEmpty else { return }
        let pack = KokoroVoiceCatalog.pack(
            fromIdentifier: SettingsStore.shared.ttsVoiceIdentifier
        ) ?? "af_heart"
        currentText = text
        spokenRange = nil
        neuralChunks = chunks
        neuralChunkIndex = 0
        state = .preparing
        // Kokoro's natural pace is 1.0; our rate slider is centered at 0.5.
        let speed = Float(SettingsStore.shared.ttsRate / 0.5)

        neuralTask = Task { @MainActor [weak self] in
            do {
                try await NeuralSpeechEngine.shared.prepare()
                // First use of a non-stock voice fetches its ~0.5 MB pack.
                try await NeuralSpeechEngine.ensureVoiceDownloaded(pack)
            } catch {
                NSLog("SpeechService: neural prepare failed (\(error)) — falling back to system voice.")
                guard let self, !Task.isCancelled, self.state == .preparing else { return }
                self.speakApple(text, voiceIdentifier: "")
                return
            }
            guard let self, !Task.isCancelled, self.state == .preparing else { return }
            self.neuralActive = true
            self.state = .speaking(paused: false)
            NeuralSpeechEngine.shared.speak(
                chunks: chunks,
                voice: pack,
                speed: speed,
                onChunkStart: { [weak self] index in
                    guard let self, self.neuralActive, index < self.neuralChunks.count else { return }
                    self.neuralChunkIndex = index
                    self.spokenRange = self.neuralChunks[index].range
                },
                onFinished: { [weak self] in
                    guard let self, self.neuralActive else { return }
                    self.neuralActive = false
                    self.neuralChunks = []
                    self.state = .idle
                    self.spokenRange = nil
                },
                onError: { [weak self] _ in
                    guard let self, self.neuralActive else { return }
                    // Finish the read with the system voice, resuming from
                    // the sentence that failed.
                    let remaining = self.neuralChunks
                        .suffix(from: min(self.neuralChunkIndex, self.neuralChunks.count))
                        .map(\.text)
                        .joined(separator: " ")
                    NeuralSpeechEngine.shared.stop()
                    self.neuralActive = false
                    self.neuralChunks = []
                    if remaining.isEmpty {
                        self.state = .idle
                        self.spokenRange = nil
                    } else {
                        self.speakApple(remaining, voiceIdentifier: "")
                    }
                }
            )
        }
    }

    // MARK: - Voice selection

    /// The user's explicit pick if it's still installed; otherwise the best
    /// installed voice for their locale (Premium > Enhanced > default).
    static func resolveVoice(preferredIdentifier: String) -> AVSpeechSynthesisVoice? {
        if !preferredIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: preferredIdentifier) {
            return voice
        }
        let candidates = AVSpeechSynthesisVoice.speechVoices().map(VoiceRanker.Candidate.init)
        let language = Locale.preferredLanguages.first ?? "en-US"
        guard let best = VoiceRanker.best(from: candidates, preferredLanguage: language) else { return nil }
        return AVSpeechSynthesisVoice(identifier: best.identifier)
    }

    // MARK: - Delegate plumbing (main-actor hops)

    fileprivate func noteWillSpeak(range: NSRange, utteranceID: ObjectIdentifier) {
        guard utteranceID == currentUtteranceID else { return }
        spokenRange = range
    }

    fileprivate func noteEnded(utteranceID: ObjectIdentifier) {
        guard utteranceID == currentUtteranceID else { return }
        currentUtteranceID = nil
        state = .idle
        spokenRange = nil
    }
}

extension SpeechService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.noteWillSpeak(range: characterRange, utteranceID: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.noteEnded(utteranceID: id) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in self.noteEnded(utteranceID: id) }
    }
}

extension VoiceRanker.Candidate {
    init(voice: AVSpeechSynthesisVoice) {
        self.init(
            identifier: voice.identifier,
            language: voice.language,
            quality: voice.quality.rawValue,
            name: voice.name,
            isNovelty: voice.voiceTraits.contains(.isNoveltyVoice),
            isPersonalVoice: voice.voiceTraits.contains(.isPersonalVoice)
        )
    }
}
