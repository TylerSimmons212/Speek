import XCTest
@testable import Speek

final class SentenceChunkerTests: XCTestCase {

    func test_simple_sentences_split_with_ranges() {
        let text = "Hello there. How are you? Fine!"
        let chunks = SentenceChunker.split(text)
        XCTAssertEqual(chunks.map(\.text), ["Hello there.", "How are you?", "Fine!"])
        // Ranges point back into the original string.
        let ns = text as NSString
        for chunk in chunks {
            XCTAssertEqual(ns.substring(with: chunk.range), chunk.text)
        }
    }

    func test_terminator_runs_and_closing_quotes_stay_attached() {
        let text = "He said \"stop!\" Then left."
        let chunks = SentenceChunker.split(text)
        XCTAssertEqual(chunks.map(\.text), ["He said \"stop!\"", "Then left."])
    }

    func test_newlines_are_boundaries() {
        let text = "First line\nSecond line"
        let chunks = SentenceChunker.split(text)
        XCTAssertEqual(chunks.map(\.text), ["First line", "Second line"])
    }

    func test_no_terminator_yields_single_chunk() {
        let chunks = SentenceChunker.split("just a fragment with no ending")
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "just a fragment with no ending")
    }

    func test_empty_and_whitespace_only_yield_nothing() {
        XCTAssertTrue(SentenceChunker.split("").isEmpty)
        XCTAssertTrue(SentenceChunker.split("   \n\n  ").isEmpty)
    }

    func test_long_sentence_subsplits_at_whitespace_under_cap() {
        let word = "supercalifragilistic"
        let text = Array(repeating: word, count: 40).joined(separator: " ")  // ~840 chars, no terminator
        let chunks = SentenceChunker.split(text, maxLength: 100)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.range.length, 100)
            // Never splits mid-word: every chunk is whole words.
            XCTAssertFalse(chunk.text.hasPrefix(String(word.dropFirst(1))))
        }
        // Reassembling the chunks recovers every word in order.
        let reassembled = chunks.map(\.text).joined(separator: " ")
        XCTAssertEqual(reassembled, text)
    }

    func test_unbreakable_run_hard_splits_rather_than_stalling() {
        let text = String(repeating: "x", count: 250)
        let chunks = SentenceChunker.split(text, maxLength: 100)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks.map(\.range.length).reduce(0, +), 250)
    }

    func test_ranges_skip_interior_whitespace() {
        let text = "One.   Two."
        let chunks = SentenceChunker.split(text)
        XCTAssertEqual(chunks.map(\.text), ["One.", "Two."])
        XCTAssertEqual(chunks[1].range.location, 7)  // whitespace not part of the chunk
    }

    func test_emoji_survive_utf16_scanning() {
        let text = "Party 🎉 time. More fun."
        let chunks = SentenceChunker.split(text)
        XCTAssertEqual(chunks.map(\.text), ["Party 🎉 time.", "More fun."])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: chunks[0].range), "Party 🎉 time.")
    }

    func test_ellipsis_is_a_boundary() {
        let chunks = SentenceChunker.split("Wait… what happened?")
        XCTAssertEqual(chunks.map(\.text), ["Wait…", "what happened?"])
    }
}
