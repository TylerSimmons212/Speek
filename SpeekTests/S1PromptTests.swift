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

    func test_prompt_renders_every_axis() {
        let style = PolishStyle(styling: .semiCasual, structure: .lists, context: .email)
        let prompt = S1Prompt.build(transcript: "test", style: style)
        XCTAssertTrue(prompt.contains("[Styling: semi-casual] [Structure: lists] [Context: email]\ntest"))
    }

    /// The model card warns that values outside the trained sets can garble
    /// output — pin the exact vocabulary so a rename can't drift from it.
    func test_axis_values_match_trained_vocabulary() {
        XCTAssertEqual(PolishStyle.Styling.allCases.map(\.rawValue), ["casual", "semi-casual", "semi-formal", "formal"])
        XCTAssertEqual(PolishStyle.Structure.allCases.map(\.rawValue), ["prose", "lists"])
        XCTAssertEqual(PolishStyle.Context.allCases.map(\.rawValue), ["general", "email"])
    }

    func test_single_chunk_keeps_full_style() {
        let style = PolishStyle(styling: .semiCasual, structure: .lists, context: .email)
        XCTAssertEqual(S1Prompt.style(style, forChunkCount: 1), style)
    }

    func test_multi_chunk_keeps_register_but_drops_layout() {
        let style = PolishStyle(styling: .semiCasual, structure: .lists, context: .email)
        XCTAssertEqual(
            S1Prompt.style(style, forChunkCount: 3),
            PolishStyle(styling: .semiCasual, structure: .prose, context: .general)
        )
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
