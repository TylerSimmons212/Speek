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

    struct Segment: Identifiable, Equatable {
        let id = UUID()
        /// Seconds from session start.
        let offset: TimeInterval
        let text: String
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var segments: [Segment] = []
    /// 0…1 level of recent system audio, drives the indicator's meter.
    @Published private(set) var audioLevel: Float = 0

    /// Set by the app once the Parakeet engine has loaded.
    var transcriber: (any TranscriptionEngine)?

    private let tap = SystemAudioTapService()
    private var pumpTask: Task<Void, Never>?
    private var gate = SilenceGateChunker()
    private var window16k: [Float] = []
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
        windowStartOffset = 0
        gate = SilenceGateChunker()
        startedAt = Date()
        state = .listening(since: startedAt)
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
        // Drain whatever the tap still holds, then flush.
        ingestDrainedAudio()
        tap.stop()
        await flushWindow()
        state = .idle
        audioLevel = 0
        NSLog("MeetingTranscription: stopped with \(segments.count) segments")
        return saveTranscript()
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
                }
            }
        }
    }

    private func ingestDrainedAudio() {
        let native = tap.drain()
        guard !native.isEmpty else { return }
        let chunk = SystemAudioTapService.resampleTo16k(native, fromRate: tap.sampleRate)
        guard !chunk.isEmpty else { return }

        if window16k.isEmpty {
            windowStartOffset = Date().timeIntervalSince(startedAt)
                - Double(chunk.count) / 16_000
        }
        window16k.append(contentsOf: chunk)

        let rms = Self.rms(chunk)
        audioLevel = min(1, rms * 4)
        gate.observe(rms: rms, duration: Double(chunk.count) / 16_000)
    }

    private func flushWindow() async {
        let window = window16k
        window16k = []
        gate.reset()
        // Sub-second windows are silence-gap artifacts, not speech.
        guard window.count >= 16_000, let transcriber else { return }
        let offset = max(0, windowStartOffset)
        do {
            let text = try await transcriber.transcribe(samples: window)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append(Segment(offset: offset, text: text))
        } catch {
            NSLog("MeetingTranscription: chunk decode failed — \(error)")
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
            lines.append("**[\(Self.timestamp(segment.offset))]** \(segment.text)")
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
