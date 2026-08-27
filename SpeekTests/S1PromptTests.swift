import XCTest
@testable import Speek

final class S1PromptTests: XCTestCase {
    // MARK: Prompt construction

    func test_prompt_contains_control_line_and_transcript() {
        let prompt = S1Prompt.build(transcript: "hello world")
        XCTAssertTrue(prompt.contains("[Styling: semi-formal] [Structure: prose] [Context: general]\nhello world"))
    }

    func test_prompt_uses_qwen3_chatml_with_empty_think_block() {
        let prompt = S1Prompt.build(transcript: "test")
        XCTAssertTrue(prompt.hasPrefix("<|im_start|>system\n"))
        // The model card is explicit: without the empty think block the
        // model returns blank output.
        XCTAssertTrue(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    func test_prompt_styling_axis() {
        let prompt = S1Prompt.build(transcript: "test", styling: .formal)
        XCTAssertTrue(prompt.contains("[Styling: formal]"))
    }

    // MARK: Output budget

    func test_max_new_tokens_follows_model_card_formula() {
        // 1.3 × input + 32
        XCTAssertEqual(S1Prompt.maxNewTokens(inputTokenCount: 100), 162)
        XCTAssertEqual(S1Prompt.maxNewTokens(inputTokenCount: 0), 32)
    }

    // MARK: Chunking

    func test_short_transcript_is_one_chunk() {
        XCTAssertEqual(S1Prompt.chunk("hello world"), ["hello world"])
    }

    func test_long_transcript_splits_at_sentence_boundaries() {
        let sentence = "this is a sentence about nothing in particular. "
        let long = String(repeating: sentence, count: 120) // ~5,900 chars
        let chunks = S1Prompt.chunk(long)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, S1Prompt.maxChunkCharacters)
            // Sentence-boundary splits: every chunk ends on a period.
            XCTAssertTrue(chunk.hasSuffix("."))
        }
    }

    func test_unpunctuated_transcript_splits_at_word_boundaries() {
        let long = String(repeating: "word ", count: 1_200) // 6,000 chars, no punctuation
        let chunks = S1Prompt.chunk(long)
        XCTAssertGreaterThan(chunks.count, 1)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, S1Prompt.maxChunkCharacters)
            XCTAssertFalse(chunk.hasPrefix(" "))
            XCTAssertFalse(chunk.hasSuffix(" "))
        }
    }

    func test_chunking_loses_no_words() {
        let sentence = "the quick brown fox jumps over the lazy dog. "
        let long = String(repeating: sentence, count: 150)
        let chunks = S1Prompt.chunk(long)
        let originalWords = long.split(whereSeparator: \.isWhitespace)
        let chunkWords = chunks.joined(separator: " ").split(whereSeparator: \.isWhitespace)
        XCTAssertEqual(originalWords, chunkWords)
    }
}
