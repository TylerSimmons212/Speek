import AppKit
import Combine
import FluidAudio
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
        /// Capture has stopped and the last window is being transcribed
        /// (a second or so). The offline speaker pass runs afterwards in the
        /// background and doesn't hold this state.
        case finalizing
        case failed(String)
    }

    enum Speaker: Equatable {
        case you
        /// Remote audio; the associated value is the diarized label
        /// ("Speaker 1") or nil when diarization is unavailable.
        case them(String?)

        var label: String {
            switch self {
            case .you: return "You"
            case .them(let name): return name ?? "Them"
            }
        }
    }

    struct Segment: Identifiable, Equatable {
        let id = UUID()
        /// Seconds from session start.
        let offset: TimeInterval
        /// Provisional (live) for remote speech until the offline pass at
        /// stop replaces it.
        var speaker: Speaker
        let text: String
        /// Where a "Them" segment's audio sits in the session's system
        /// track (seconds), for the offline relabel. Nil for "You".
        var trackSpan: OfflineSpeakerRelabeler.Span? = nil
        /// Track-timeline span of each whitespace-separated word of `text`,
        /// so the offline relabel can split the segment where the speaker
        /// changes. Empty for "You" or when the engine had no timings.
        var wordSpans: [OfflineSpeakerRelabeler.Span] = []
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
    /// Identifies distinct remote speakers within the system-audio track.
    private let diarizer = MeetingDiarizer()
    private var speakerLabeler = SpeakerLabeler()
    /// The whole session's 16 kHz system track, spooled to disk for the
    /// offline diarization pass at stop.
    private var systemSpool: SystemTrackSpool?
    /// Samples of system track seen this session (the spool's timeline,
    /// counted separately so spans stay right even if the spool fails).
    private var systemTrackSamples = 0
    /// System-track index where the in-flight window's audio begins.
    private var windowTrackStart = 0
    /// LocalVQE on the mic track (Settings → Audio, beta). Decided at start.
    private let echoCanceller = MeetingEchoCanceller()
    private var echoCancellationEnabled = false
    /// Meeting-dedicated mic capture ("You" track) — a second engine
    /// instance; macOS happily feeds the mic to both this and dictation.
    private let mic = AudioCaptureService()
    private var micTask: Task<Void, Never>?
    /// Mic chunks pushed by the stream reader, drained by the pump.
    private var micPending: [Float] = []
    private var systemResampler: StreamResampler?
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

    var isFinalizing: Bool { state == .finalizing }

    var elapsed: TimeInterval {
        if case .listening(let since) = state { return Date().timeIntervalSince(since) }
        return 0
    }

    private init() {}

    // MARK: - Control

    func start() {
        guard !isListening, !isFinalizing else { return }
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
        speakerLabeler = SpeakerLabeler()
        systemSpool = SystemTrackSpool()
        if systemSpool == nil {
            NSLog("MeetingTranscription: couldn't create system-track spool; live speaker labels only")
        }
        systemTrackSamples = 0
        windowTrackStart = 0
        startedAt = Date()
        state = .listening(since: startedAt)
        // Diarization models load in the background (download on first use);
        // early windows label as plain "Them" until ready.
        Task { await diarizer.startSession() }
        echoCancellationEnabled = SettingsStore.shared.meetingEchoCancellation
        if echoCancellationEnabled {
            // Mic passes through raw until the model is ready.
            Task { await echoCanceller.start() }
        }
        startMicTrack()
        startPump()
        NSLog("MeetingTranscription: started")
    }

    /// Stops capture, flushes the final chunk, writes the transcript.
    /// Returns the transcript file URL (nil if nothing was transcribed).
    ///
    /// The file is written right away with the live speaker labels; an
    /// offline diarization pass over the whole system track then rewrites it
    /// in place with better "Them" labels (~1.5 s per minute of audio on an
    /// M1 Pro). Running that in the background keeps stop instant, keeps the
    /// transcript safe if the app quits mid-pass, and lets a back-to-back
    /// meeting start immediately.
    @discardableResult
    func stop() async -> URL? {
        guard isListening else { return nil }
        state = .finalizing
        audioLevel = 0
        let stopRequested = Date()
        // Let an in-flight tick (decode, enhance) finish first so it can't
        // interleave with the final drain below.
        let pump = pumpTask
        pumpTask = nil
        pump?.cancel()
        await pump?.value
        micTask?.cancel()
        micTask = nil
        // Drain whatever both tracks still hold (tap.stop() discards its
        // buffer), then flush.
        await ingestDrainedAudio()
        tap.stop()
        await mic.stop()
        if echoCancellationEnabled {
            appendMic(await echoCanceller.finish())
        }
        await flushWindow()

        let offlineModels = await diarizer.takeOfflineModels()
        await diarizer.endSession()
        let snapshot = segments
        let sessionStart = startedAt
        let hasRemoteSpeech = snapshot.contains { $0.trackSpan != nil }
        let track = hasRemoteSpeech && offlineModels != nil ? systemSpool?.finish() : nil
        let trackDuration = systemSpool?.duration ?? 0
        // Unlinks the temp file; `track` keeps reading its mapping.
        systemSpool = nil
        state = .idle

        let body = Self.renderTranscript(snapshot, startedAt: sessionStart)
        let url = snapshot.isEmpty ? nil : Self.writeTranscript(body, startedAt: sessionStart)
        NSLog(String(
            format: "MeetingTranscription: stopped with %d segments — stop→file %.2fs",
            snapshot.count, Date().timeIntervalSince(stopRequested)
        ))

        if let url, let track, let offlineModels {
            Task.detached(priority: .utility) {
                await Self.relabelTranscript(
                    snapshot, track: track, trackDuration: trackDuration, models: offlineModels,
                    url: url, provisionalBody: body, startedAt: sessionStart, stopRequested: stopRequested
                )
            }
        } else if url != nil, hasRemoteSpeech {
            NSLog("MeetingTranscription: offline diarization models weren't ready; keeping live speaker labels")
        }
        return url
    }

    /// Re-diarizes the whole system track and rewrites the transcript with
    /// the relabeled "Them" segments. Any failure keeps the live labels, and
    /// a transcript the user has edited since it was written is left alone.
    nonisolated private static func relabelTranscript(
        _ segments: [Segment],
        track: MappedPCM16Source,
        trackDuration: TimeInterval,
        models: OfflineDiarizerModels,
        url: URL,
        provisionalBody: String,
        startedAt: Date,
        stopRequested: Date
    ) async {
        let started = Date()
        do {
            let turns = try await MeetingDiarizer.diarizeFullTrack(track, models: models)
            guard let relabeled = relabeledSegments(segments, turns: turns) else {
                NSLog("MeetingTranscription: offline diarization found no speech; keeping live labels")
                return
            }
            // Segments kept whole keep their ID; split ones become new parts.
            let original = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0.speaker) })
            let whole = relabeled.filter { $0.trackSpan != nil && original[$0.id] != nil }
            let changed = whole.filter { original[$0.id] != $0.speaker }.count
            let remote = segments.filter { $0.trackSpan != nil }.count
            let parts = relabeled.filter { $0.trackSpan != nil }.count - whole.count
            let speakers = Set(turns.map(\.speakerId)).count
            NSLog(String(
                format: "MeetingTranscription: offline diarization over %.0fs of audio in %.2fs — %d speakers, %d/%d remote segments relabeled, %d split at speaker changes into %d parts",
                trackDuration, Date().timeIntervalSince(started), speakers, changed, remote, remote - whole.count, parts
            ))
            let body = renderTranscript(relabeled, startedAt: startedAt)
            guard body != provisionalBody else { return }
            guard (try? String(contentsOf: url, encoding: .utf8)) == provisionalBody else {
                NSLog("MeetingTranscription: transcript changed since it was written; not applying offline labels")
                return
            }
            try body.write(to: url, atomically: true, encoding: .utf8)
            NSLog(String(format: "MeetingTranscription: relabeled transcript written — stop→relabeled file %.2fs", Date().timeIntervalSince(stopRequested)))
        } catch {
            NSLog("MeetingTranscription: offline diarization failed; keeping live labels — \(error)")
        }
    }

    /// `segments` with every "Them" segment relabeled from the offline
    /// `turns`: by maximum timestamp overlap, and split in two or more where
    /// its words cross a speaker change. "You" segments are untouched.
    /// Nil when the offline pass found nothing (keep the live labels).
    nonisolated static func relabeledSegments(_ segments: [Segment], turns: [OfflineSpeakerRelabeler.Turn]) -> [Segment]? {
        let remote = segments.indices.filter { segments[$0].trackSpan != nil }
        let items = remote.map { index in
            let segment = segments[index]
            var live: String?
            if case .them(let label) = segment.speaker { live = label }
            let aligned = TimedTranscript.wordCount(segment.text) == segment.wordSpans.count
            return OfflineSpeakerRelabeler.Item(
                span: segment.trackSpan!, provisionalLabel: live, words: aligned ? segment.wordSpans : []
            )
        }
        guard let parts = OfflineSpeakerRelabeler.relabelSplitting(items: items, turns: turns) else { return nil }
        let partsByIndex = Dictionary(uniqueKeysWithValues: zip(remote, parts))
        var result: [Segment] = []
        result.reserveCapacity(segments.count)
        for (index, segment) in segments.enumerated() {
            guard let segmentParts = partsByIndex[index] else {
                result.append(segment)
                continue
            }
            result += split(segment, into: segmentParts)
        }
        return result
    }

    /// One segment per part: the part's words of `text`, its label, and a
    /// timestamp moved to where its first word starts. A single part
    /// relabels the segment in place.
    nonisolated static func split(_ segment: Segment, into parts: [OfflineSpeakerRelabeler.Part]) -> [Segment] {
        let words = segment.text.split(whereSeparator: \.isWhitespace)
        guard parts.count > 1, let span = segment.trackSpan, words.count == segment.wordSpans.count else {
            var whole = segment
            whole.speaker = .them(parts.first?.label)
            return [whole]
        }
        return parts.enumerated().map { position, part in
            let start = position == 0 ? span.start : segment.wordSpans[part.words.lowerBound].start
            let end = position == parts.count - 1 ? span.end : segment.wordSpans[parts[position + 1].words.lowerBound].start
            return Segment(
                offset: segment.offset + max(0, start - span.start),
                speaker: .them(part.label),
                text: words[part.words].joined(separator: " "),
                trackSpan: OfflineSpeakerRelabeler.Span(start: start, end: max(start, end)),
                wordSpans: Array(segment.wordSpans[part.words])
            )
        }
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
                    } else if self.echoCancellationEnabled {
                        // Keep the mic timeline continuous for the echo
                        // canceller's alignment; silence never attributes.
                        self.micPending.append(contentsOf: [Float](repeating: 0, count: chunk.count))
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
                await self.ingestDrainedAudio()
                if self.gate.shouldFlush(windowDuration: Double(self.window16k.count) / 16_000) {
                    await self.flushWindow()
                } else if self.livePreviewActive, self.window16k.count >= 16_000,
                          let transcriber = self.transcriber {
                    // Live preview: re-decode the in-flight window; the merger
                    // locks stable words so the display doesn't flicker. Runs
                    // inline, so a slow decode naturally throttles the cadence
                    // (same backpressure design as the dictation preview).
                    let snapshot = self.window16k
                    if let text = try? await transcriber.transcribePreview(samples: snapshot) {
                        guard self.livePreviewActive else { continue }
                        self.livePartial = self.partialMerger.merge(text)
                    }
                }
            }
        }
    }

    private func ingestDrainedAudio() async {
        // System track ("Them").
        let native = tap.drain()
        // Session-persistent resampler: keeps converter state across drains
        // (a fresh converter per 500ms chunk resets the filter at every
        // boundary and drifts by the truncated fractional samples).
        if systemResampler?.fromRate != tap.sampleRate {
            systemResampler = StreamResampler(fromRate: tap.sampleRate)
        }
        let systemChunk = native.isEmpty
            ? []
            : (systemResampler?.resample(native) ?? [])
        // Mic track ("You") — already 16kHz mono from AudioCaptureService.
        var micChunk = micPending
        micPending.removeAll(keepingCapacity: true)
        if echoCancellationEnabled {
            // The tap is the far-end reference: what the speakers played.
            micChunk = await echoCanceller.process(mic: micChunk, reference: systemChunk)
        }

        guard !systemChunk.isEmpty || !micChunk.isEmpty else { return }

        if window16k.isEmpty && micWindow16k.isEmpty {
            let dominantCount = max(systemChunk.count, micChunk.count)
            windowStartOffset = Date().timeIntervalSince(startedAt)
                - Double(dominantCount) / 16_000
        }
        if window16k.isEmpty {
            windowTrackStart = systemTrackSamples
        }
        window16k.append(contentsOf: systemChunk)
        systemSpool?.append(systemChunk)
        systemTrackSamples += systemChunk.count
        micWindow16k.append(contentsOf: micChunk)

        let systemRMS = Self.rms(systemChunk)
        let micRMS = Self.rms(micChunk)
        systemActivity.observe(rms: systemRMS, duration: Double(systemChunk.count) / 16_000, threshold: activityThreshold)
        micActivity.observe(rms: micRMS, duration: Double(micChunk.count) / 16_000, threshold: activityThreshold)

        // Indicator meter and the flush gate follow the louder track — the
        // conversation pauses only when BOTH sides go quiet.
        let combined = max(systemRMS, micRMS)
        if isListening {
            audioLevel = min(1, combined * 4)
        }
        let clockDuration = Double(max(systemChunk.count, micChunk.count)) / 16_000
        gate.observe(rms: combined, duration: clockDuration)
    }

    /// Late mic audio (the echo canceller's tail at stop) joins the
    /// in-flight window.
    private func appendMic(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        micWindow16k.append(contentsOf: samples)
        micActivity.observe(rms: Self.rms(samples), duration: Double(samples.count) / 16_000, threshold: activityThreshold)
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
        let trackSpan = OfflineSpeakerRelabeler.Span(
            start: Double(windowTrackStart) / 16_000,
            end: Double(windowTrackStart + systemWindow.count) / 16_000
        )

        // Them first (the call audio is usually the conversational anchor),
        // then You. Sub-second windows are silence-gap artifacts — skip.
        if verdict.them, systemWindow.count >= 16_000 {
            // Windows are pause-bounded and usually single-voiced; the
            // dominant diarized speaker labels the whole segment live. The
            // offline pass at stop splits the ones that hold two voices.
            var speaker = Speaker.them(nil)
            if let id = await diarizer.dominantSpeakerId(in: systemWindow) {
                speaker = .them(speakerLabeler.label(forId: id))
            }
            await appendSegment(speaker: speaker, samples: systemWindow, offset: offset, trackSpan: trackSpan, transcriber: transcriber)
        }
        if verdict.you, micWindow.count >= 16_000 {
            await appendSegment(speaker: .you, samples: micWindow, offset: offset, trackSpan: nil, transcriber: transcriber)
        }
    }

    private func appendSegment(
        speaker: Speaker,
        samples: [Float],
        offset: TimeInterval,
        trackSpan: OfflineSpeakerRelabeler.Span?,
        transcriber: any TranscriptionEngine
    ) async {
        do {
            var wordSpans: [OfflineSpeakerRelabeler.Span] = []
            let text: String
            if let trackSpan {
                // Remote speech: keep word timings (window-relative) on the
                // track timeline, for splitting at offline speaker changes.
                let decoded = try await transcriber.transcribeWithWordTimings(samples: samples)
                text = decoded.text
                wordSpans = decoded.words.map {
                    OfflineSpeakerRelabeler.Span(start: trackSpan.start + $0.start, end: trackSpan.start + $0.end)
                }
            } else {
                text = try await transcriber.transcribe(samples: samples)
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            segments.append(Segment(offset: offset, speaker: speaker, text: trimmed, trackSpan: trackSpan, wordSpans: wordSpans))
        } catch {
            NSLog("MeetingTranscription: \(speaker.label) chunk decode failed — \(error)")
        }
    }

    // MARK: - Transcript output

    nonisolated static func renderTranscript(_ segments: [Segment], startedAt: Date) -> String {
        var lines = ["# Meeting Transcript — \(startedAt.formatted(date: .abbreviated, time: .shortened))", ""]
        for segment in segments {
            lines.append("**[\(timestamp(segment.offset))] \(segment.speaker.label):** \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func writeTranscript(_ body: String, startedAt: Date) -> URL? {
        let dir = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speek Transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        let url = dir.appendingPathComponent("Meeting \(formatter.string(from: startedAt)).md")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            NSLog("MeetingTranscription: transcript save failed — \(error)")
            return nil
        }
    }

    nonisolated static func timestamp(_ offset: TimeInterval) -> String {
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
