import XCTest
@testable import Speek

/// Splitting a pause-bounded "Them" segment where the offline turns change
/// speaker partway through its words.
final class OfflineSpeakerSplitTests: XCTestCase {
    private typealias R = OfflineSpeakerRelabeler

    private func turn(_ id: String, _ start: Double, _ end: Double) -> R.Turn {
        R.Turn(speakerId: id, start: start, end: end)
    }

    private func words(_ spans: [(Double, Double)]) -> [R.Span] {
        spans.map { R.Span(start: $0.0, end: $0.1) }
    }

    private func item(_ start: Double, _ end: Double, live: String? = nil, words: [R.Span] = []) -> R.Item {
        R.Item(span: R.Span(start: start, end: end), provisionalLabel: live, words: words)
    }

    private func labels(_ parts: [R.Part]?) -> [String?]? {
        parts?.map(\.label)
    }

    // MARK: - Splitting

    func test_window_holding_two_speakers_splits_at_the_turn_change() throws {
        // A finishes, a 1 s pause the gate didn't flush on, B answers.
        let segment = item(0, 4, words: words([(0, 0.4), (0.5, 0.9), (1.0, 1.4), (2.4, 2.8), (2.9, 3.3), (3.4, 3.8)]))
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: [turn("A", 0, 1.5), turn("B", 2.3, 4)]))
        XCTAssertEqual(parts, [[
            R.Part(words: 0..<3, label: "Speaker 1"),
            R.Part(words: 3..<6, label: "Speaker 2"),
        ]])
    }

    func test_back_and_forth_inside_one_window_gives_one_part_per_turn() throws {
        let segment = item(0, 6, words: words([(0, 0.5), (0.6, 1.1), (1.8, 2.3), (2.4, 2.9), (3.6, 4.1), (4.2, 4.7)]))
        let turns = [turn("A", 0, 1.2), turn("B", 1.7, 3.0), turn("A", 3.5, 4.8)]
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: turns))
        XCTAssertEqual(parts.first?.map(\.words), [0..<2, 2..<4, 4..<6])
        XCTAssertEqual(labels(parts.first), ["Speaker 1", "Speaker 2", "Speaker 1"])
    }

    func test_one_speaker_window_stays_whole_with_the_whole_segment_label() throws {
        let segments = [
            item(0, 3, words: words([(0.1, 0.5), (0.6, 1.0), (1.1, 1.5)])),
            item(4, 6, words: words([(4.1, 4.5), (4.6, 5.0)])),
        ]
        let turns = [turn("S2", 0, 3), turn("S1", 4, 6)]
        let parts = try XCTUnwrap(R.relabelSplitting(items: segments, turns: turns))
        XCTAssertEqual(parts, [[R.Part(words: 0..<3, label: "Speaker 1")], [R.Part(words: 0..<2, label: "Speaker 2")]])
        XCTAssertEqual(parts.map { $0[0].label }, R.relabel(items: segments, turns: turns))
    }

    func test_a_word_barely_inside_the_next_turn_does_not_split() throws {
        // The last word's tail runs 0.15 s into B's turn — decoder-frame and
        // diarizer-boundary jitter, not a reply.
        let segment = item(0, 2, words: words([(0, 0.4), (0.5, 0.9), (1.0, 1.4), (1.5, 1.9)]))
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: [turn("A", 0, 1.6), turn("B", 1.75, 5)]))
        XCTAssertEqual(parts, [[R.Part(words: 0..<4, label: "Speaker 1")]])
    }

    func test_a_one_word_reply_with_its_own_turn_still_splits() throws {
        // "…before Friday." "Right."
        let segment = item(0, 2.5, words: words([(0, 0.4), (0.5, 0.9), (1.0, 1.4), (1.9, 2.3)]))
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: [turn("A", 0, 1.45), turn("C", 1.85, 2.35)]))
        XCTAssertEqual(parts.first?.map(\.words), [0..<3, 3..<4])
    }

    func test_weak_middle_run_folds_into_its_stronger_neighbor() throws {
        // A 1.2 s, a 0.2 s blip of B, then C 0.6 s: the blip joins A.
        let segment = item(0, 2.6, words: words([(0, 0.4), (0.5, 0.9), (1.0, 1.4), (1.5, 1.7), (1.8, 2.1), (2.2, 2.5)]))
        let turns = [turn("A", 0, 1.45), turn("B", 1.5, 1.7), turn("C", 1.75, 2.6)]
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: turns))
        XCTAssertEqual(parts, [[
            R.Part(words: 0..<4, label: "Speaker 1"),
            R.Part(words: 4..<6, label: "Speaker 2"),
        ]])
    }

    func test_words_outside_every_turn_join_the_speaker_before_them() throws {
        // The leading word (before any turn) joins the first run, the word
        // in the pause joins A, the trailing word joins B.
        let segment = item(0, 4, words: words([(0, 0.3), (0.6, 1.0), (1.1, 1.4), (1.8, 2.1), (2.6, 3.0), (3.1, 3.4), (3.8, 4.0)]))
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: [turn("A", 0.5, 1.5), turn("B", 2.5, 3.5)]))
        XCTAssertEqual(parts.first?.map(\.words), [0..<4, 4..<7])
    }

    func test_ordinals_follow_first_appearance_across_parts() throws {
        // Offline IDs are arbitrary; the transcript numbers them in reading order.
        let items = [
            item(0, 4, words: words([(0, 0.5), (0.6, 1.1), (2.0, 2.5), (2.6, 3.1)])),
            item(5, 7, words: words([(5.1, 5.6), (5.7, 6.2)])),
        ]
        let turns = [turn("S3", 0, 1.2), turn("S1", 1.9, 3.2), turn("S1", 5, 7)]
        let parts = try XCTUnwrap(R.relabelSplitting(items: items, turns: turns))
        XCTAssertEqual(parts.map(labels), [["Speaker 1", "Speaker 2"], ["Speaker 2"]])
    }

    // MARK: - Fallbacks

    func test_segment_without_word_timings_keeps_the_whole_segment_fallbacks() throws {
        // No timings → whole segment, and the far-off stray still follows its
        // live label's offline match.
        let items = [
            item(0, 4, live: "Speaker 1"),
            item(5, 9, live: "Speaker 2"),
            item(40, 42, live: "Speaker 2"),
        ]
        let parts = try XCTUnwrap(R.relabelSplitting(items: items, turns: [turn("A", 0, 4), turn("B", 5, 9)]))
        XCTAssertEqual(parts, [
            [R.Part(words: 0..<0, label: "Speaker 1")],
            [R.Part(words: 0..<0, label: "Speaker 2")],
            [R.Part(words: 0..<0, label: "Speaker 2")],
        ])
    }

    func test_words_that_touch_no_turn_keep_the_segment_whole() throws {
        let segment = item(10, 12, words: words([(10.2, 10.6), (10.8, 11.2)]))
        let parts = try XCTUnwrap(R.relabelSplitting(items: [segment], turns: [turn("A", 0, 9.5)]))
        XCTAssertEqual(parts, [[R.Part(words: 0..<2, label: "Speaker 1")]], "nearest-turn fallback labels it whole")
    }

    func test_no_offline_turns_keeps_live_labels() {
        XCTAssertNil(R.relabelSplitting(items: [item(0, 4, live: "Speaker 1", words: words([(0, 1)]))], turns: []))
    }
}

final class TimedTranscriptTests: XCTestCase {
    private typealias W = TimedTranscript.Word

    private func decoded(_ count: Int) -> [W] {
        (0..<count).map { W(start: Double($0), end: Double($0) + 0.5) }
    }

    func test_decoder_words_pair_one_to_one_with_text_words() {
        let timed = TimedTranscript(text: "Hello there, friend.", decodedWords: decoded(3))
        XCTAssertEqual(timed.words, decoded(3))
    }

    func test_rewritten_text_borrows_timings_by_relative_position() {
        // A post-pass merged two words ("chat gpt" → "ChatGPT").
        let merged = TimedTranscript(text: "ask ChatGPT now", decodedWords: decoded(4))
        XCTAssertEqual(merged.words.map(\.start), [0, 1, 2])
        // …or split one.
        let split = TimedTranscript(text: "a b c d e", decodedWords: decoded(4))
        XCTAssertEqual(split.words.map(\.start), [0, 0, 1, 2, 3])
    }

    func test_no_timings_or_no_text_gives_no_words() {
        XCTAssertEqual(TimedTranscript(text: "hello", decodedWords: []).words, [])
        XCTAssertEqual(TimedTranscript(text: "  ", decodedWords: decoded(2)).words, [])
    }
}

@MainActor
final class MeetingSegmentSplitTests: XCTestCase {
    private typealias Segment = MeetingTranscriptionService.Segment
    private typealias R = OfflineSpeakerRelabeler

    private func span(_ start: Double, _ end: Double) -> R.Span {
        R.Span(start: start, end: end)
    }

    func test_split_parts_carry_their_own_text_label_and_timestamp() throws {
        // Window at 10 s into the session = 0 s on the system track.
        let window = Segment(
            offset: 10, speaker: .them("Speaker 1"), text: "Thanks everyone. Sounds good to me.",
            trackSpan: span(0, 4),
            wordSpans: [span(0, 0.4), span(0.5, 1.2), span(2.4, 2.8), span(2.9, 3.1), span(3.2, 3.4), span(3.5, 3.8)]
        )
        let segments = [window, Segment(offset: 14, speaker: .you, text: "Great.")]
        let turns = [R.Turn(speakerId: "A", start: 0, end: 1.3), R.Turn(speakerId: "B", start: 2.3, end: 4)]

        let relabeled = try XCTUnwrap(MeetingTranscriptionService.relabeledSegments(segments, turns: turns))
        XCTAssertEqual(relabeled.map(\.speaker.label), ["Speaker 1", "Speaker 2", "You"])
        XCTAssertEqual(relabeled.map(\.text), ["Thanks everyone.", "Sounds good to me.", "Great."])
        XCTAssertEqual(relabeled[1].offset, 12.4, accuracy: 1e-9)
        XCTAssertEqual(relabeled[0].trackSpan, span(0, 2.4))
        XCTAssertEqual(relabeled[1].trackSpan, span(2.4, 4))
        XCTAssertEqual(relabeled[1].wordSpans.count, 4)

        let body = MeetingTranscriptionService.renderTranscript(relabeled, startedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(body.contains("**[00:10] Speaker 1:** Thanks everyone.\n"))
        XCTAssertTrue(body.contains("**[00:12] Speaker 2:** Sounds good to me.\n"))
        XCTAssertTrue(body.contains("**[00:14] You:** Great."))
    }

    func test_word_spans_that_do_not_match_the_text_relabel_the_segment_whole() throws {
        let window = Segment(
            offset: 0, speaker: .them(nil), text: "three words here",
            trackSpan: span(0, 4), wordSpans: [span(0, 1), span(3, 4)]
        )
        let turns = [R.Turn(speakerId: "A", start: 0, end: 1.5), R.Turn(speakerId: "B", start: 2.5, end: 4)]
        let relabeled = try XCTUnwrap(MeetingTranscriptionService.relabeledSegments([window], turns: turns))
        XCTAssertEqual(relabeled.map(\.text), ["three words here"])
        XCTAssertEqual(relabeled.map(\.id), [window.id])
        XCTAssertEqual(relabeled.map(\.speaker.label), ["Speaker 1"])
    }
}
