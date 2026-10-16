import XCTest
@testable import Speek

final class OfflineSpeakerRelabelerTests: XCTestCase {
    private typealias R = OfflineSpeakerRelabeler

    private func turn(_ id: String, _ start: Double, _ end: Double) -> R.Turn {
        R.Turn(speakerId: id, start: start, end: end)
    }

    private func item(_ start: Double, _ end: Double, live: String? = nil) -> R.Item {
        R.Item(span: R.Span(start: start, end: end), provisionalLabel: live)
    }

    // MARK: - Overlap

    func test_largest_overlap_wins() {
        let turns = [turn("A", 0, 1), turn("B", 1, 4)]
        XCTAssertEqual(R.dominantSpeaker(for: R.Span(start: 0, end: 4), in: turns), "B")
    }

    func test_overlap_is_summed_per_speaker_across_turns() {
        // A: 2 + 1.5 = 3.5s, B: 1.5s — A wins despite B's turn sitting mid-span.
        let turns = [turn("A", 0, 2), turn("B", 2, 3.5), turn("A", 3.5, 5)]
        XCTAssertEqual(R.dominantSpeaker(for: R.Span(start: 0, end: 6), in: turns), "A")
    }

    func test_turns_outside_the_span_do_not_count() {
        let turns = [turn("A", 0, 10), turn("B", 10, 11)]
        XCTAssertEqual(R.dominantSpeaker(for: R.Span(start: 10, end: 11), in: turns), "B")
    }

    func test_touching_but_not_overlapping_is_no_overlap() {
        XCTAssertNil(R.dominantSpeaker(for: R.Span(start: 5, end: 6), in: [turn("A", 0, 5)]))
    }

    func test_exact_tie_breaks_deterministically() {
        let turns = [turn("B", 0, 1), turn("A", 1, 2)]
        XCTAssertEqual(R.dominantSpeaker(for: R.Span(start: 0, end: 2), in: turns), "A")
    }

    // MARK: - Labels

    func test_ordinals_follow_first_appearance_in_transcript_order() {
        // Offline IDs are arbitrary ("S3" first); transcript order numbers them.
        let turns = [turn("S3", 0, 5), turn("S1", 5, 10)]
        let labels = R.relabel(items: [item(0, 4), item(6, 9), item(1, 3)], turns: turns)
        XCTAssertEqual(labels, ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func test_one_voice_that_drifted_live_collapses_to_one_label() {
        // Short live windows split one remote voice into three "speakers".
        let items = [
            item(0, 3, live: "Speaker 1"),
            item(4, 6, live: "Speaker 2"),
            item(7, 12, live: "Speaker 1"),
            item(13, 15, live: "Speaker 3"),
        ]
        let labels = R.relabel(items: items, turns: [turn("X", 0, 15.5)])
        XCTAssertEqual(labels, Array(repeating: "Speaker 1", count: 4))
    }

    func test_two_voices_merged_live_are_split() {
        let items = [
            item(0, 4, live: "Speaker 1"),
            item(5, 9, live: "Speaker 1"),
            item(10, 14, live: "Speaker 1"),
        ]
        let turns = [turn("A", 0, 4.2), turn("B", 4.8, 9.1), turn("A", 9.8, 14)]
        XCTAssertEqual(R.relabel(items: items, turns: turns), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func test_segment_without_overlap_borrows_a_nearby_turn() {
        // The diarizer trimmed this window's edges; the nearest turn ends
        // 0.6s before it starts.
        let labels = R.relabel(items: [item(0, 4), item(10, 12)], turns: [turn("A", 0, 4), turn("B", 6, 9.4)])
        XCTAssertEqual(labels, ["Speaker 1", "Speaker 2"])
    }

    func test_segment_far_from_any_turn_uses_its_live_label_mapping() {
        // "Speaker 2" (live) consistently overlapped offline "B" elsewhere,
        // so the stray "Speaker 2" segment at 40s follows B.
        let items = [
            item(0, 4, live: "Speaker 1"),
            item(5, 9, live: "Speaker 2"),
            item(40, 42, live: "Speaker 2"),
        ]
        let turns = [turn("A", 0, 4), turn("B", 5, 9)]
        XCTAssertEqual(R.relabel(items: items, turns: turns), ["Speaker 1", "Speaker 2", "Speaker 2"])
    }

    func test_segment_with_no_overlap_and_no_live_mapping_renders_as_them() {
        let items = [item(0, 4, live: "Speaker 1"), item(40, 42, live: "Speaker 7"), item(50, 52)]
        let labels = R.relabel(items: items, turns: [turn("A", 0, 4)])
        XCTAssertEqual(labels, ["Speaker 1", nil, nil])
    }

    func test_live_mapping_uses_overlap_weighted_majority() {
        // Live "Speaker 1" covered 8s of A and 2s of B → strays map to A.
        let items = [
            item(0, 8, live: "Speaker 1"),
            item(10, 12, live: "Speaker 1"),
            item(100, 101, live: "Speaker 1"),
        ]
        let turns = [turn("A", 0, 8), turn("B", 10, 12)]
        XCTAssertEqual(R.relabel(items: items, turns: turns), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func test_no_offline_turns_keeps_live_labels() {
        XCTAssertNil(R.relabel(items: [item(0, 4, live: "Speaker 1")], turns: []))
    }

    func test_no_remote_segments_yields_no_labels() {
        XCTAssertEqual(R.relabel(items: [], turns: [turn("A", 0, 1)]), [])
    }
}

@MainActor
final class MeetingSegmentRelabelTests: XCTestCase {
    private typealias Segment = MeetingTranscriptionService.Segment
    private typealias R = OfflineSpeakerRelabeler

    private func them(_ label: String?, _ start: Double, _ end: Double, _ text: String) -> Segment {
        Segment(offset: start, speaker: .them(label), text: text, trackSpan: R.Span(start: start, end: end))
    }

    func test_only_remote_segments_are_relabeled() {
        let segments = [
            them("Speaker 1", 0, 4, "hello"),
            Segment(offset: 4, speaker: .you, text: "hi"),
            them("Speaker 2", 6, 9, "same person as before"),
            them("Speaker 1", 10, 13, "a new voice"),
        ]
        let turns = [
            R.Turn(speakerId: "A", start: 0, end: 9),
            R.Turn(speakerId: "B", start: 10, end: 13),
        ]
        let relabeled = MeetingTranscriptionService.relabeledSegments(segments, turns: turns)
        XCTAssertEqual(relabeled?.map(\.speaker.label), ["Speaker 1", "You", "Speaker 1", "Speaker 2"])
        XCTAssertEqual(relabeled?.map(\.text), segments.map(\.text))
        XCTAssertEqual(relabeled?.map(\.id), segments.map(\.id), "segments are relabeled in place, not rebuilt")
    }

    func test_empty_offline_result_keeps_live_labels() {
        let segments = [them("Speaker 3", 0, 4, "hello")]
        XCTAssertNil(MeetingTranscriptionService.relabeledSegments(segments, turns: []))
    }

    func test_relabel_is_visible_in_the_written_transcript() throws {
        let segments = [them("Speaker 2", 0, 4, "hello"), Segment(offset: 5, speaker: .you, text: "hi")]
        let relabeled = try XCTUnwrap(MeetingTranscriptionService.relabeledSegments(
            segments, turns: [R.Turn(speakerId: "Z", start: 0, end: 4)]
        ))
        let body = MeetingTranscriptionService.renderTranscript(relabeled, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(body.contains("**[00:00] Speaker 1:** hello"))
        XCTAssertTrue(body.contains("**[00:05] You:** hi"))
    }
}
