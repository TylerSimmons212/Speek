import Foundation

/// Replaces a meeting's provisional, per-window speaker labels with labels
/// from one offline diarization pass over the whole system-audio track.
///
/// Live labels come from diarizing each pause-bounded window in isolation
/// (often 2–5 s, below what the online diarizer handles well), so the same
/// voice can drift between "Speaker 1" and "Speaker 3" over a call. The
/// offline pass sees the full session at once; each "Them" segment takes the
/// offline speaker it overlaps most.
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
    }

    /// A segment with no overlapping turn borrows the nearest turn when it
    /// is at most this far away (the diarizer's speech boundaries are a
    /// little tighter than the gate's pause-bounded windows).
    static let nearestTurnTolerance: TimeInterval = 1.0

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
        var overlap: [String: TimeInterval] = [:]
        for turn in turns {
            let amount = min(span.end, turn.end) - max(span.start, turn.start)
            if amount > 0 {
                overlap[turn.speakerId, default: 0] += amount
            }
        }
        return overlap.max { lhs, rhs in
            lhs.value == rhs.value ? lhs.key > rhs.key : lhs.value < rhs.value
        }?.key
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
