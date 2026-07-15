import FluidAudio
import Foundation

/// Identifies WHO is speaking in the system-audio track using FluidAudio's
/// on-device diarization models (speaker embeddings + clustering — same
/// pipeline family as pyannote, running on CoreML). One instance per meeting
/// session keeps speaker identities consistent across chunks; a new session
/// starts numbering fresh.
///
/// Best-effort: if the models can't load (first-run download failure), the
/// meeting proceeds with plain "Them" labels.
actor MeetingDiarizer {
    private var manager: DiarizerManager?

    /// Loads (downloading on first use) the diarization models and starts a
    /// fresh speaker-tracking session.
    func startSession() async {
        manager = nil
        do {
            let models = try await DiarizerModels.downloadIfNeeded()
            let manager = DiarizerManager()
            manager.initialize(models: models)
            self.manager = manager
        } catch {
            NSLog("MeetingDiarizer: unavailable, falling back to plain labels — \(error)")
        }
    }

    func endSession() {
        manager?.cleanup()
        manager = nil
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
