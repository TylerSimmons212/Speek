import AppKit
import Combine
import Foundation

/// Live transcription of whatever is playing on the Mac — video calls,
/// videos, anything — via the system-audio tap. Runs quietly alongside
/// dictation (the notch shows a compact recording indicator), accumulates
/// timestamped segments, and writes a Markdown transcript on stop.
@MainActor
final class MeetingTranscriptionService: ObservableObject {
    static let shared = MeetingTranscriptionService()

    enum State: Equatable {
        case idle
        case listening(since: Date)
        case failed(String)
    }

    enum Speaker: String, Equatable {
        case you = "You"
        case them = "Them"
    }

    struct Segment: Identifiable, Equatable {
        let id = UUID()
        /// Seconds from session start.
        let offset: TimeInterval
        let speaker: Speaker
        let text: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var segments: [Segment] = []
    /// 0…1 level of recent system audio, drives the indicator's meter.
    @Published private(set) var audioLevel: Float = 0
    /// Rolling decode of the in-flight window — only produced while
    /// `livePreviewActive` (the notch is expanded under the cursor), so the
    /// ANE isn't decoding continuously for a transcript nobody is watching.
    @Published private(set) var livePartial: String = ""

    /// Set by the indicator when the user expands the notch. Toggling off
    /// clears the preview state.
    var livePreviewActive = false {
        didSet {
            guard livePreviewActive != oldValue, !livePreviewActive else { return }
            livePartial = ""
            partialMerger = PartialTranscriptMerger()
        }
    }
    private var partialMerger = PartialTranscriptMerger()

    /// Set by the app once the Parakeet engine has loaded.
    var transcriber: (any TranscriptionEngine)?

    private let tap = SystemAudioTapService()
    /// Meeting-dedicated mic capture ("You" track) — a second engine
    /// instance; macOS happily feeds the mic to both this and dictation.
    private let mic = AudioCaptureService()
    private var micTask: Task<Void, Never>?
    /// Mic chunks pushed by the stream reader, drained by the pump.
    private var micPending: [Float] = []
    /// True while the user is dictating — their speech is going to the
    /// dictation pipeline, not the meeting, so the You-track pauses.
    var micSuppressed = false

    private var pumpTask: Task<Void, Never>?
    private var gate = SilenceGateChunker()
    private var window16k: [Float] = []
    private var micWindow16k: [Float] = []
    private var systemActivity = SpeakerAttributor.TrackActivity()
    private var micActivity = SpeakerAttributor.TrackActivity()
    /// Speech-presence threshold for attribution (RMS).
    private let activityThreshold: Float = 0.012
    private var windowStartOffset: TimeInterval = 0
    private var startedAt = Date()

    var isListening: Bool {
        if case .listening = state { return true }
        return false
    }

    var elapsed: TimeInterval {
        if case .listening(let since) = state { return Date().timeIntervalSince(since) }
        return 0
    }

    private init() {}

    // MARK: - Control

    func start() {
        guard !isListening else { return }
        guard transcriber != nil else {
            state = .failed("Speech model not loaded yet.")
            return
        }
        do {
            try tap.start()
        } catch {
            state = .failed(error.localizedDescription)
            NSLog("MeetingTranscription: tap start failed — \(error)")
            return
        }
        segments = []
        window16k = []
        micWindow16k = []
        micPending = []
        systemActivity = SpeakerAttributor.TrackActivity()
        micActivity = SpeakerAttributor.TrackActivity()
        windowStartOffset = 0
        gate = SilenceGateChunker()
        startedAt = Date()
        state = .listening(since: startedAt)
        startMicTrack()
        startPump()
        NSLog("MeetingTranscription: started")
    }

    /// Stops capture, flushes the final chunk, writes the transcript.
    /// Returns the transcript file URL (nil if nothing was transcribed).
    @discardableResult
    func stop() async -> URL? {
        guard isListening else { return nil }
        pumpTask?.cancel()
        pumpTask = nil
        micTask?.cancel()
        micTask = nil
        // Drain whatever both tracks still hold, then flush.
        ingestDrainedAudio()
        tap.stop()
        await mic.stop()
        await flushWindow()
        state = .idle
        audioLevel = 0
        NSLog("MeetingTranscription: stopped with \(segments.count) segments")
        return saveTranscript()
    }

    /// Reads the meeting mic stream ("You" track) into micPending.
    private func startMicTrack() {
        micTask = Task { [weak self] in
            guard let self else { return }
            do {
                let stream = try await self.mic.start()
                for await chunk in stream {
                    guard !Task.isCancelled else { return }
                    if !self.micSuppressed {
                        self.micPending.append(contentsOf: chunk)
                    }
                }
            } catch {
                // Mic track is best-effort: fall back to system-only
                // transcription (segments become all-Them).
                NSLog("MeetingTranscription: mic track failed — \(error)")
            }
        }
    }

    // MARK: - Pump

    private func startPump() {
        pumpTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                self.ingestDrainedAudio()
                if self.gate.shouldFlush(windowDuration: Double(self.window16k.count) / 16_000) {
                    await self.flushWindow()
                } else if self.livePreviewActive, self.window16k.count >= 16_000,
                          let transcriber = self.transcriber {
                    // Live preview: re-decode the in-flight window; the merger
                    // locks stable words so the display doesn't flicker. Runs
                    // inline, so a slow decode naturally throttles the cadence
                    // (same backpressure design as the dictation preview).
                    let snapshot = self.window16k
                    if let text = try? await transcriber.transcribe(samples: snapshot) {
                        guard self.livePreviewActive else { continue }
                        self.livePartial = self.partialMerger.merge(text)
                    }
                }
            }
        }
    }

    private func ingestDrainedAudio() {
        // System track ("Them").
        let native = tap.drain()
        let systemChunk = native.isEmpty
            ? []
            : SystemAudioTapService.resampleTo16k(native, fromRate: tap.sampleRate)
        // Mic track ("You") — already 16kHz mono from AudioCaptureService.
        let micChunk = micPending
        micPending.removeAll(keepingCapacity: true)

        guard !systemChunk.isEmpty || !micChunk.isEmpty else { return }

        if window16k.isEmpty && micWindow16k.isEmpty {
            let dominantCount = max(systemChunk.count, micChunk.count)
            windowStartOffset = Date().timeIntervalSince(startedAt)
                - Double(dominantCount) / 16_000
        }
        window16k.append(contentsOf: systemChunk)
        micWindow16k.append(contentsOf: micChunk)

        let systemRMS = Self.rms(systemChunk)
        let micRMS = Self.rms(micChunk)
        systemActivity.observe(rms: systemRMS, duration: Double(systemChunk.count) / 16_000, threshold: activityThreshold)
        micActivity.observe(rms: micRMS, duration: Double(micChunk.count) / 16_000, threshold: activityThreshold)

        // Indicator meter and the flush gate follow the louder track — the
        // conversation pauses only when BOTH sides go quiet.
        let combined = max(systemRMS, micRMS)
        audioLevel = min(1, combined * 4)
        let clockDuration = Double(max(systemChunk.count, micChunk.count)) / 16_000
        gate.observe(rms: combined, duration: clockDuration)
    }

    private func flushWindow() async {
        let systemWindow = window16k
        let micWindow = micWindow16k
        let verdict = SpeakerAttributor.attribute(mic: micActivity, system: systemActivity)
        window16k = []
        micWindow16k = []
        systemActivity = SpeakerAttributor.TrackActivity()
        micActivity = SpeakerAttributor.TrackActivity()
        gate.reset()
        // The flushed audio becomes permanent segments — reset the preview
        // so it starts fresh on the next window.
        livePartial = ""
        partialMerger = PartialTranscriptMerger()

        guard let transcriber else { return }
        let offset = max(0, windowStartOffset)

        // Them first (the call audio is usually the conversational anchor),
        // then You. Sub-second windows are silence-gap artifacts — skip.
        if verdict.them, systemWindow.count >= 16_000 {
            await appendSegment(speaker: .them, samples: systemWindow, offset: offset, transcriber: transcriber)
        }
        if verdict.you, micWindow.count >= 16_000 {
            await appendSegment(speaker: .you, samples: micWindow, offset: offset, transcriber: transcriber)
        }
    }

    private func appendSegment(
        speaker: Speaker,
        samples: [Float],
        offset: TimeInterval,
        transcriber: any TranscriptionEngine
    ) async {
        do {
            let text = try await transcriber.transcribe(samples: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(Segment(offset: offset, speaker: speaker, text: text))
        } catch {
            NSLog("MeetingTranscription: \(speaker.rawValue) chunk decode failed — \(error)")
        }
    }

    // MARK: - Transcript output

    private func saveTranscript() -> URL? {
        guard !segments.isEmpty else { return nil }
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speek Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = dir.appendingPathComponent("Meeting \(formatter.string(from: startedAt)).md")

        var lines = ["# Meeting Transcript — \(startedAt.formatted(date: .abbreviated, time: .shortened))", ""]
        for segment in segments {
            lines.append("**[\(Self.timestamp(segment.offset))] \(segment.speaker.rawValue):** \(segment.text)")
            lines.append("")
        }
        let body = lines.joined(separator: "\n")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("MeetingTranscription: transcript save failed — \(error)")
            return nil
        }
    }

    static func timestamp(_ offset: TimeInterval) -> String {
        let total = Int(offset.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func rms(_ chunk: [Float]) -> Float {
        guard !chunk.isEmpty else { return 0 }
        var sum: Float = 0
        for s in chunk { sum += s * s }
        return (sum / Float(chunk.count)).squareRoot()
    }
}

/// Decides when the accumulated audio window should be decoded: after a
/// natural pause (silence run) once enough speech has built up, or at a hard
/// cap so very long monologues still produce timely segments.
struct SilenceGateChunker {
    /// RMS below this is "silence" for gating purposes.
    var silenceThreshold: Float = 0.008
    /// A pause this long ends a chunk…
    var silenceRunToFlush: TimeInterval = 0.8
    /// …but only once the window holds at least this much audio.
    var minWindowDuration: TimeInterval = 2.0
    /// Decode no matter what past this window length.
    var maxWindowDuration: TimeInterval = 15.0

    private var silenceRun: TimeInterval = 0

    mutating func observe(rms: Float, duration: TimeInterval) {
        if rms < silenceThreshold {
            silenceRun += duration
        } else {
            silenceRun = 0
        }
    }

    func shouldFlush(windowDuration: TimeInterval) -> Bool {
        if windowDuration >= maxWindowDuration { return true }
        return windowDuration >= minWindowDuration && silenceRun >= silenceRunToFlush
    }

    mutating func reset() {
        silenceRun = 0
    }
}
