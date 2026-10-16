import FluidAudio
import Foundation

/// Removes far-end (speaker) audio from the meeting mic track with
/// FluidAudio's LocalVQE model, using the system-audio tap as the echo
/// reference. On a laptop-speaker call the mic hears the remote side through
/// the speakers; without this, that pickup can become duplicate "You"
/// segments whenever the RMS bleed rule misjudges it.
///
/// Beta (LocalVQE itself is beta in FluidAudio): best-effort throughout —
/// until the model loads, or after any inference error, the mic passes
/// through untouched.
actor MeetingEchoCanceller {
    private var stream: LocalVqeStream?
    private var aligner = EchoReferenceAligner()
    /// Leading enhanced samples that belong to the aligner's mic prefill.
    private var prefillToDiscard = 0
    private var corrections = 0
    /// Bumped by every start/finish, so a model load that completes after
    /// its meeting already ended doesn't switch the canceller on.
    private var generation = 0

    private(set) var isActive = false

    /// Loads (downloading ~19 MB on first use) the model and opens a stream.
    func start() async {
        generation += 1
        let session = generation
        isActive = false
        stream = nil
        do {
            // 256 ms calls: the meeting pump hands over ~500 ms per tick,
            // and the batch chunk is ~2.5x cheaper than the 16 ms one.
            let manager = try await LocalVqeManager(config: LocalVqeConfig(variant: .v13, chunk: .batch256ms))
            let stream = try await manager.makeStream()
            guard session == generation else { return }
            self.stream = stream
            aligner = EchoReferenceAligner()
            prefillToDiscard = aligner.prefill
            corrections = 0
            isActive = true
            NSLog("MeetingEchoCanceller: LocalVQE ready")
        } catch {
            NSLog("MeetingEchoCanceller: unavailable, mic passes through — \(error)")
        }
    }

    /// Enhances one tick of mic audio against the same tick's reference.
    /// Output trails input by the aligner's prefill plus up to one model
    /// call; `finish()` returns the remainder. Returns `mic` unchanged while
    /// inactive.
    func process(mic: [Float], reference: [Float]) async -> [Float] {
        guard isActive, let stream else { return mic }
        let pair = aligner.push(mic: mic, reference: reference)
        if aligner.corrections != corrections {
            corrections = aligner.corrections
            NSLog("MeetingEchoCanceller: re-aligned reference (skew drifted), corrections=\(corrections)")
        }
        do {
            let enhanced = try await stream.enhance(mic: pair.mic, reference: pair.reference)
            return discardPrefill(enhanced)
        } catch {
            NSLog("MeetingEchoCanceller: enhance failed, passing mic through — \(error)")
            isActive = false
            self.stream = nil
            // Samples inside the model's buffer are lost with the clip; hand
            // back everything still queued here.
            return discardPrefill(pair.mic + aligner.drain().mic)
        }
    }

    /// End of session: enhances everything still queued and drains the
    /// model's delay line, so total output length matches total mic input.
    func finish() async -> [Float] {
        generation += 1
        defer {
            isActive = false
            stream = nil
        }
        guard isActive, let stream else { return [] }
        let pair = aligner.drain()
        do {
            var out = try await stream.enhance(mic: pair.mic, reference: pair.reference)
            out += try await stream.flush()
            return discardPrefill(out)
        } catch {
            NSLog("MeetingEchoCanceller: final flush failed — \(error)")
            return discardPrefill(pair.mic)
        }
    }

    private func discardPrefill(_ samples: [Float]) -> [Float] {
        guard prefillToDiscard > 0 else { return samples }
        let drop = min(prefillToDiscard, samples.count)
        prefillToDiscard -= drop
        return Array(samples.dropFirst(drop))
    }
}

/// Pairs mic and reference samples for the echo canceller.
///
/// The two tracks come from different devices: they start at different
/// moments (the tap is up before the mic engine), run on independent clocks,
/// and the mic stops feeding while the user dictates. Both are drained at
/// the same instants, though, so `skew` — queued mic minus queued reference —
/// tracks how far the mic sits behind the reference in real time.
///
/// The canceller needs far-end audio no later than its echo reaches the mic
/// (it looks back over a history window, but can't look ahead), so the mic is
/// held `targetSkew` behind with a zero prefill. When drift pushes the skew
/// outside `lowWater…highWater`, the reference — never the mic — is skipped
/// or silence-padded back to the target. The mic timeline is untouched apart
/// from the prefill, which the caller discards from the output.
struct EchoReferenceAligner {
    /// 100 ms of reference lead: comfortably inside LocalVQE's delay window,
    /// and enough slack for device-latency and drain jitter.
    let targetSkew: Int
    /// Reference more than 50 ms ahead of the mic queue: the mic started
    /// late, stalled, or its clock is slow — skip reference.
    let lowWater: Int
    /// Mic more than 300 ms ahead: the tap stalled or its clock is slow —
    /// pad the reference with silence.
    let highWater: Int

    private var mic: [Float]
    private var reference: [Float] = []
    private var referenceToSkip = 0
    private(set) var corrections = 0

    var prefill: Int { targetSkew }

    init(targetSkew: Int = 1_600, lowWater: Int = -800, highWater: Int = 4_800) {
        precondition(lowWater < targetSkew && targetSkew < highWater)
        self.targetSkew = targetSkew
        self.lowWater = lowWater
        self.highWater = highWater
        self.mic = [Float](repeating: 0, count: targetSkew)
    }

    /// Positive: mic samples waiting on reference. Negative: the reverse.
    var skew: Int { mic.count - reference.count + referenceToSkip }

    /// Queues one drain's worth of each track and returns every sample pair
    /// that's ready (equal lengths, possibly empty).
    mutating func push(mic newMic: [Float], reference newReference: [Float]) -> (mic: [Float], reference: [Float]) {
        mic.append(contentsOf: newMic)
        reference.append(contentsOf: newReference)

        let current = skew
        if current < lowWater {
            referenceToSkip += targetSkew - current
            corrections += 1
        } else if current > highWater {
            var excess = current - targetSkew
            let cancelled = min(referenceToSkip, excess)
            referenceToSkip -= cancelled
            excess -= cancelled
            reference.append(contentsOf: repeatElement(0, count: excess))
            corrections += 1
        }
        let skip = min(referenceToSkip, reference.count)
        reference.removeFirst(skip)
        referenceToSkip -= skip

        let ready = min(mic.count, reference.count)
        let out = (mic: Array(mic.prefix(ready)), reference: Array(reference.prefix(ready)))
        mic.removeFirst(ready)
        reference.removeFirst(ready)
        return out
    }

    /// Pairs every queued mic sample (silence-padding the reference) and
    /// empties the queues.
    mutating func drain() -> (mic: [Float], reference: [Float]) {
        if reference.count < mic.count {
            reference.append(contentsOf: repeatElement(0, count: mic.count - reference.count))
        }
        let out = (mic: mic, reference: Array(reference.prefix(mic.count)))
        mic = []
        reference = []
        referenceToSkip = 0
        return out
    }
}
