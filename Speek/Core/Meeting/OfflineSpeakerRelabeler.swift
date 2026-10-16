import Foundation

/// Replaces a meeting's provisional, per-window speaker labels with labels
/// from one offline diarization pass over the whole system-audio track.
///
/// Live labels come from diarizing each pause-bounded window in isolation
/// (often 2–5 s, below what the online diarizer handles well), so the same
/// voice can drift between "Speaker 1" and "Speaker 3" over a call. The
/// offline pass sees the full session at once; each "Them" segment takes the
/// offline speaker it overlaps most, and a segment whose words cross a
/// speaker change is split there (`relabelSplitting`).
enum OfflineSpeakerRelabeler {
    /// One diarized speaker turn on the system-track timeline (seconds).
    struct Turn: Equatable {
        var speakerId: String
        var start: TimeInterval
        var end: TimeInterval
    }

    /// Where a transcript segment sits on the system-track timeline.
    struct Span: Equatable {
        var start: TimeInterval
        var end: TimeInterval
    }

    struct Item: Equatable {
        var span: Span
        /// The live label ("Speaker 2"), nil when live diarization was
        /// unavailable for that window.
        var provisionalLabel: String?
        /// Where each of the segment's words sits on the track timeline, in
        /// order. Lets `relabelSplitting` cut the segment where the speaker
        /// changes; empty keeps it whole.
        var words: [Span] = []
    }

    /// One piece of a segment after `relabelSplitting`.
    struct Part: Equatable {
        /// Indices into the item's `words`; `0..<0` when it had none.
        var words: Range<Int>
        /// Display label; nil renders as "Them".
        var label: String?
    }

    /// A segment with no overlapping turn borrows the nearest turn when it
    /// is at most this far away (the diarizer's speech boundaries are a
    /// little tighter than the gate's pause-bounded windows).
    static let nearestTurnTolerance: TimeInterval = 1.0

    /// A speaker change inside a segment only splits it when the new
    /// speaker's words overlap their turns by at least this much. Below
    /// that, a stray word at a turn edge (80 ms decoder frames against the
    /// diarizer's boundaries) or a blip of a turn would cut a sentence.
    static let minimumPartSpeech: TimeInterval = 0.3

    /// Final display labels, index-aligned with `items`: "Speaker N" ordinals
    /// numbered by first appearance in transcript order. Nil means the
    /// offline pass couldn't place that segment (it renders as "Them").
    ///
    /// Returns nil when `turns` is empty, so the caller keeps the live labels
    /// rather than wiping them because the offline pass found nothing.
    static func relabel(items: [Item], turns: [Turn]) -> [String?]? {
        guard !turns.isEmpty else { return nil }
        let speakerIds = assignSpeakers(items: items, turns: turns)
        var labeler = SpeakerLabeler()
        return speakerIds.map { id in id.map { labeler.label(forId: $0) } }
    }

    /// Like `relabel`, but a segment whose words fall in more than one
    /// offline speaker's turns comes back as several parts, one per speaker
    /// run, in order. Pause-bounded windows often hold two voices (a reply
    /// that follows a short pause); the offline turns say where to cut.
    /// Segments without word timings, or whose words all belong to one
    /// speaker, stay whole with the label `relabel` would give them.
    /// Ordinals follow first appearance across the parts.
    ///
    /// Returns nil when `turns` is empty (keep the live labels).
    static func relabelSplitting(
        items: [Item], turns: [Turn], minimumPartSpeech: TimeInterval = Self.minimumPartSpeech
    ) -> [[Part]]? {
        guard !turns.isEmpty else { return nil }
        let whole = assignSpeakers(items: items, turns: turns)
        var labeler = SpeakerLabeler()
        return items.indices.map { index in
            let runs = speakerRuns(of: items[index], turns: turns, minimumPartSpeech: minimumPartSpeech)
            guard runs.count > 1 else {
                let label = whole[index].map { labeler.label(forId: $0) }
                return [Part(words: items[index].words.indices, label: label)]
            }
            return runs.map { Part(words: $0.words, label: labeler.label(forId: $0.speakerId)) }
        }
    }

    /// Consecutive words of one segment attributed to one offline speaker.
    struct Run: Equatable {
        var speakerId: String
        var words: Range<Int>
        /// How much of the run's words overlap its speaker's turns (seconds).
        var speech: TimeInterval
    }

    /// The item's words grouped into consecutive same-speaker runs:
    /// 1. each word takes the speaker whose turns it overlaps most;
    /// 2. a word no turn touches joins the speaker before it (or after it,
    ///    at the start of the segment);
    /// 3. runs with less than `minimumPartSpeech` of support fold into
    ///    their stronger neighbor, weakest first.
    /// Empty when the item has no words or none overlaps a turn.
    static func speakerRuns(
        of item: Item, turns: [Turn], minimumPartSpeech: TimeInterval = Self.minimumPartSpeech
    ) -> [Run] {
        guard let first = item.words.first, let last = item.words.last else { return [] }
        let low = min(item.span.start, first.start)
        let high = max(item.span.end, last.end)
        let nearby = turns.filter { $0.end > low && $0.start < high }
        let assigned = item.words.map { strongestOverlap(for: $0, in: nearby) }
        guard var current = assigned.lazy.compactMap({ $0?.id }).first else { return [] }

        var runs: [Run] = []
        for (index, word) in assigned.enumerated() {
            if let word { current = word.id }
            let speech = word?.seconds ?? 0
            if runs.last?.speakerId == current {
                runs[runs.count - 1].words = runs[runs.count - 1].words.lowerBound..<(index + 1)
                runs[runs.count - 1].speech += speech
            } else {
                runs.append(Run(speakerId: current, words: index..<(index + 1), speech: speech))
            }
        }

        while runs.count > 1,
              let weakest = runs.indices.min(by: { runs[$0].speech < runs[$1].speech }),
              runs[weakest].speech < minimumPartSpeech {
            let target: Int
            if weakest == 0 {
                target = 1
            } else if weakest == runs.count - 1 {
                target = weakest - 1
            } else {
                target = runs[weakest + 1].speech > runs[weakest - 1].speech ? weakest + 1 : weakest - 1
            }
            let merged = min(runs[weakest].words.lowerBound, runs[target].words.lowerBound)
                ..< max(runs[weakest].words.upperBound, runs[target].words.upperBound)
            runs[target].words = merged
            runs.remove(at: weakest)
            runs = coalesced(runs)
        }
        return runs
    }

    /// Joins neighboring runs of the same speaker.
    private static func coalesced(_ runs: [Run]) -> [Run] {
        var result: [Run] = []
        for run in runs {
            if let last = result.last, last.speakerId == run.speakerId {
                result[result.count - 1].words = last.words.lowerBound..<run.words.upperBound
                result[result.count - 1].speech += run.speech
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// The offline speaker ID for each item:
    /// 1. the turn speaker with the most total overlap;
    /// 2. else the nearest turn within `nearestTurnTolerance`;
    /// 3. else whichever offline speaker the item's provisional label most
    ///    often matched elsewhere in the session (by overlap duration);
    /// 4. else nil.
    static func assignSpeakers(items: [Item], turns: [Turn]) -> [String?] {
        var assigned: [String?] = items.map { dominantSpeaker(for: $0.span, in: turns) }

        // Learn provisional → offline correspondences from the items that
        // overlapped, weighted by overlap, to place the stragglers.
        var votes: [String: [String: TimeInterval]] = [:]
        for (index, item) in items.enumerated() {
            guard let provisional = item.provisionalLabel, let offline = assigned[index] else { continue }
            let weight = max(item.span.end - item.span.start, 0.001)
            votes[provisional, default: [:]][offline, default: 0] += weight
        }
        let mapping = votes.compactMapValues { tally in
            tally.max { lhs, rhs in
                lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
            }?.key
        }

        for index in items.indices where assigned[index] == nil {
            if let near = nearestSpeaker(to: items[index].span, in: turns, tolerance: nearestTurnTolerance) {
                assigned[index] = near
            } else if let provisional = items[index].provisionalLabel {
                assigned[index] = mapping[provisional]
            }
        }
        return assigned
    }

    /// The speaker whose turns overlap `span` the longest; nil if none do.
    /// Ties break toward the lexicographically smaller ID for determinism.
    static func dominantSpeaker(for span: Span, in turns: [Turn]) -> String? {
        strongestOverlap(for: span, in: turns)?.id
    }

    /// The speaker whose turns overlap `span` the longest, and by how much.
    static func strongestOverlap(for span: Span, in turns: [Turn]) -> (id: String, seconds: TimeInterval)? {
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let amount = min(span.end, turn.end) - max(span.start, turn.start)
            if amount > 0 {
                overlap[turn.speakerId, default: 0] += amount
            }
        }
        return overlap.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }.map { ($0.key, $0.value) }
    }

    static func nearestSpeaker(to span: Span, in turns: [Turn], tolerance: TimeInterval) -> String? {
        var best: (id: String, gap: TimeInterval)?
        for turn in turns {
            let gap: TimeInterval
            if turn.end <= span.start {
                gap = span.start - turn.end
            } else if turn.start >= span.end {
                gap = turn.start - span.end
            } else {
                gap = 0
            }
            guard gap <= tolerance else { continue }
            if best == nil || gap < best!.gap {
                best = (turn.speakerId, gap)
            }
        }
        return best?.id
    }
}
