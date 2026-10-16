import FluidAudio
import Foundation

/// Identifies WHO is speaking in the system-audio track using FluidAudio's
/// on-device diarization models (speaker embeddings + clustering — same
/// pipeline family as pyannote, running on CoreML). One instance per meeting
/// session keeps speaker identities consistent across chunks; a new session
/// starts numbering fresh.
///
/// Two passes:
/// - **Live** (`dominantSpeakerId`): the online `DiarizerManager` labels each
///   pause-bounded window as it's transcribed. These labels are provisional —
///   windows are often shorter than the ~5 s the online diarizer wants.
/// - **Offline** (`diarizeFullTrack`): after stop, FluidAudio's offline
///   pipeline (pyannote community-1 segmentation + WeSpeaker embeddings +
///   VBx) runs over the whole system-audio track, and its turns replace the
///   live labels in the written transcript. Its models load at session start
///   so the pass never waits on a download; if they aren't ready by stop
///   (first-ever compile is ~100 s on an M1 Pro) the live labels stand.
///
/// Best-effort: if the models can't load (first-run download failure), the
/// meeting proceeds with plain "Them" labels (live) or keeps the live labels
/// (offline).
actor MeetingDiarizer {
    private var manager: DiarizerManager?
    /// Loaded at session start, in parallel with the live models, so stop
    /// doesn't pay for a download or compile. Released at session end.
    private var offlineModels: OfflineDiarizerModels?
    private var offlineLoad: Task<OfflineDiarizerModels, Error>?

    /// Loads (downloading on first use) the diarization models and starts a
    /// fresh speaker-tracking session.
    func startSession() async {
        manager = nil
        let load = offlineLoad ?? Task { try await OfflineDiarizerModels.load() }
        offlineLoad = load
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
        } catch {
            NSLog("MeetingDiarizer: unavailable, falling back to plain labels — \(error)")
        }
        do {
            let models = try await load.value
            // endSession may have run while this was loading.
            if offlineLoad == load { offlineModels = models }
        } catch {
            NSLog("MeetingDiarizer: offline models unavailable, live labels only — \(error)")
        }
        if offlineLoad == load { offlineLoad = nil }
    }

    func endSession() {
        manager?.cleanup()
        manager = nil
        // An in-flight load finishes on its own (its compile is cached on
        // disk for next time); its result is dropped.
        offlineLoad = nil
        offlineModels = nil
    }

    /// Hands the loaded offline models to the caller (nil if they hadn't
    /// finished loading). The offline pass runs outside this actor, so the
    /// next meeting's session can start while it's still going.
    func takeOfflineModels() -> OfflineDiarizerModels? {
        defer { offlineModels = nil }
        return offlineModels
    }

    /// Diarizes a complete session track in one pass: pyannote community-1
    /// segmentation, WeSpeaker embeddings, VBx clustering. Throws on
    /// inference failure — the caller keeps the live labels.
    nonisolated static func diarizeFullTrack(
        _ source: some AudioSampleSource,
        models: OfflineDiarizerModels
    ) async throws -> [OfflineSpeakerRelabeler.Turn] {
        let offline = OfflineDiarizerManager(config: .default)
        offline.initialize(models: models)
        let result = try await offline.process(audioSource: source, audioLoadingSeconds: 0)
        return result.segments.map {
            OfflineSpeakerRelabeler.Turn(
                speakerId: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    /// The dominant speaker ID in the window (by total speaking time), or
    /// nil when diarization is unavailable or found nothing.
    func dominantSpeakerId(in samples16k: [Float]) -> String? {
        guard let manager else { return nil }
        do {
            let result = try manager.performCompleteDiarization(samples16k, sampleRate: 16_000)
            var durations: [String: Float] = [:]
            for segment in result.segments {
                durations[segment.speakerId, default: 0] += segment.durationSeconds
            }
            return durations.max(by: { $0.value < $1.value })?.key
        } catch {
            NSLog("MeetingDiarizer: diarization failed for window — \(error)")
            return nil
        }
    }
}

/// Maps the diarizer's opaque speaker IDs to stable, human-friendly ordinals
/// for one session: the first voice heard is "Speaker 1", the next "Speaker
/// 2", and IDs keep their number for the whole meeting.
struct SpeakerLabeler {
    private var ordinals: [String: Int] = [:]

    mutating func label(forId id: String) -> String {
        if let existing = ordinals[id] {
            return "Speaker \(existing)"
        }
        let next = ordinals.count + 1
        ordinals[id] = next
        return "Speaker \(next)"
    }
}
