import XCTest
@testable import Speek

final class CorrectionLearnerTests: XCTestCase {
    func test_detects_single_word_substitution() {
        let diff = CorrectionLearner.detectSingleWordSubstitution(
            from: "Let's meet Wrold tomorrow",
            to:   "Let's meet World tomorrow"
        )
        XCTAssertEqual(diff?.original, "Wrold")
        XCTAssertEqual(diff?.replacement, "World")
    }

    func test_ignores_identical_text() {
        XCTAssertNil(CorrectionLearner.detectSingleWordSubstitution(
            from: "hello world",
            to:   "hello world"
        ))
    }

    func test_ignores_multi_word_changes() {
        XCTAssertNil(CorrectionLearner.detectSingleWordSubstitution(
            from: "the quick brown fox",
            to:   "the slow grey fox"
        ))
    }

    func test_ignores_word_count_changes() {
        XCTAssertNil(CorrectionLearner.detectSingleWordSubstitution(
            from: "hello",
            to:   "hello world"
        ))
    }

    func test_returns_nil_on_empty_input() {
        XCTAssertNil(CorrectionLearner.detectSingleWordSubstitution(from: "", to: ""))
    }

    // MARK: - Contextual phrase learning

    func test_proper_noun_expands_forward() {
        let pair = CorrectionLearner.learnedPhrase(
            from: "Try Whisper Flow today",
            to:   "Try Wispr Flow today"
        )
        XCTAssertEqual(pair?.original, "Whisper Flow")
        XCTAssertEqual(pair?.replacement, "Wispr Flow")
    }

    func test_proper_noun_expands_backward() {
        let pair = CorrectionLearner.learnedPhrase(
            from: "the new Tyler Smyth profile",
            to:   "the new Tyler Smith profile"
        )
        XCTAssertEqual(pair?.original, "Tyler Smyth")
        XCTAssertEqual(pair?.replacement, "Tyler Smith")
    }

    func test_proper_noun_strips_trailing_punctuation() {
        let pair = CorrectionLearner.learnedPhrase(
            from: "We tried Whisper Flow.",
            to:   "We tried Wispr Flow."
        )
        XCTAssertEqual(pair?.original, "Whisper Flow")
        XCTAssertEqual(pair?.replacement, "Wispr Flow")
    }

    func test_lowercase_word_doesnt_expand() {
        // Diff word is lowercase → just learn the single word.
        let pair = CorrectionLearner.learnedPhrase(
            from: "the wrold is round",
            to:   "the world is round"
        )
        XCTAssertEqual(pair?.original, "wrold")
        XCTAssertEqual(pair?.replacement, "world")
    }

    func test_doesnt_pull_in_sentence_initial_word() {
        // "Hello" is capitalized only because it starts the sentence — not part
        // of the name. Expect just "Tylor" → "Tyler".
        let pair = CorrectionLearner.learnedPhrase(
            from: "Hello Tylor",
            to:   "Hello Tyler"
        )
        XCTAssertEqual(pair?.original, "Tylor")
        XCTAssertEqual(pair?.replacement, "Tyler")
    }
}
