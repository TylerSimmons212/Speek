import XCTest
@testable import Speek

final class SpokenTextWindowTests: XCTestCase {

    func test_nil_range_shows_head_of_text() {
        let slice = SpokenTextWindow.slice(text: "Hello world.", spokenRange: nil)
        XCTAssertEqual(slice.before, "")
        XCTAssertEqual(slice.current, "")
        XCTAssertEqual(slice.after, "Hello world.")
    }

    func test_word_mid_sentence_highlights_with_context() {
        let text = "The quick brown fox jumps."
        let range = (text as NSString).range(of: "brown")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.before, "The quick ")
        XCTAssertEqual(slice.current, "brown")
        XCTAssertEqual(slice.after, " fox jumps.")
    }

    func test_window_starts_at_sentence_boundary() {
        let text = "First sentence ends here. Second one continues along."
        let range = (text as NSString).range(of: "continues")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        // Previous sentence (and the whitespace after its period) is dropped.
        XCTAssertEqual(slice.before, "Second one ")
        XCTAssertEqual(slice.current, "continues")
        XCTAssertEqual(slice.after, " along.")
    }

    func test_runon_text_clamps_lookback() {
        // No terminators at all — the window is clamped to maxBefore.
        let filler = String(repeating: "word ", count: 100)  // 500 chars, no terminator
        let text = filler + "TARGET rest"
        let range = (text as NSString).range(of: "TARGET")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertLessThanOrEqual(slice.before.utf16.count, SpokenTextWindow.maxBefore)
        XCTAssertEqual(slice.current, "TARGET")
    }

    func test_long_tail_clamps_after() {
        let text = "START " + String(repeating: "tail ", count: 200)
        let range = (text as NSString).range(of: "START")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.current, "START")
        XCTAssertLessThanOrEqual(slice.after.utf16.count, SpokenTextWindow.maxAfter)
    }

    func test_last_word_has_empty_after() {
        let text = "Read to the end."
        let range = (text as NSString).range(of: "end")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.current, "end")
        XCTAssertEqual(slice.after, ".")
    }

    func test_stale_out_of_bounds_range_treated_as_nil() {
        let slice = SpokenTextWindow.slice(
            text: "Short.",
            spokenRange: NSRange(location: 100, length: 5)
        )
        XCTAssertEqual(slice.current, "")
        XCTAssertEqual(slice.after, "Short.")
    }

    func test_first_word_of_text() {
        let text = "Hello there."
        let range = (text as NSString).range(of: "Hello")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.before, "")
        XCTAssertEqual(slice.current, "Hello")
        XCTAssertEqual(slice.after, " there.")
    }

    func test_emoji_before_word_survives_utf16_math() {
        let text = "Fun 🎉 party time."
        let range = (text as NSString).range(of: "party")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.before, "Fun 🎉 ")
        XCTAssertEqual(slice.current, "party")
        XCTAssertEqual(slice.after, " time.")
    }

    func test_newline_is_a_sentence_boundary() {
        let text = "Line one\nLine two goes on."
        let range = (text as NSString).range(of: "two")
        let slice = SpokenTextWindow.slice(text: text, spokenRange: range)
        XCTAssertEqual(slice.before, "Line ")
        XCTAssertEqual(slice.current, "two")
    }
}
