import FluidAudio
import XCTest
@testable import Speek

final class VocabularyRescorePolicyTests: XCTestCase {
    private let policy = VocabularyRescorePolicy(context: VocabularyBoostMapping.context(from: [
        "wisper flo": "Wispr Flow",
        "super wisper": "Superwhisper",
        "to be": "Toby",
    ])!)

    private func splice(_ text: String, _ pairs: [(String, String)]) -> String {
        policy.splice(pairs.map { .init(span: $0.0, term: $0.1) }, into: text)
    }

    // MARK: - Splice

    func test_replaces_span_in_place() {
        XCTAssertEqual(
            splice("Tyler wants the Whisper Flow comparison.", [("Whisper Flow", "Wispr Flow")]),
            "Tyler wants the Wispr Flow comparison."
        )
    }

    func test_keeps_a_leading_function_word_the_rescorer_swallowed() {
        XCTAssertEqual(
            splice("Whisperflow and SuperWhisper both ship.", [("and SuperWhisper", "Superwhisper")]),
            "Whisperflow and Superwhisper both ship."
        )
        XCTAssertEqual(
            splice("Send me the SuperWhisper notes.", [("the SuperWhisper", "Superwhisper")]),
            "Send me the Superwhisper notes."
        )
    }

    func test_keeps_punctuation_the_span_carried() {
        XCTAssertEqual(
            splice("Notes are in Super Whisper. Thanks!", [("Super Whisper.", "Superwhisper")]),
            "Notes are in Superwhisper. Thanks!"
        )
        XCTAssertEqual(
            splice("He said \"Super Whisper,\" twice", [("\"Super Whisper,\"", "Superwhisper")]),
            "He said \"Superwhisper,\" twice"
        )
    }

    func test_rejects_span_padded_with_a_function_word_to_fit_a_longer_term() {
        let text = "Please whisper the answer if you know it."
        XCTAssertEqual(splice(text, [("whisper the", "Wispr Flow")]), text)
    }

    func test_exact_alias_made_of_function_words_is_replaced_whole() {
        XCTAssertEqual(splice("Ask to be about it.", [("to be", "Toby")]), "Ask Toby about it.")
    }

    func test_span_missing_from_transcript_is_ignored() {
        let text = "Nothing to see here."
        XCTAssertEqual(splice(text, [("Whisper Flow", "Wispr Flow")]), text)
    }

    func test_matches_span_by_normalized_form_when_text_differs() {
        XCTAssertEqual(
            splice("Try Super Whisper, then decide.", [("super whisper", "Superwhisper")]),
            "Try Superwhisper, then decide."
        )
    }

    func test_repeated_phrase_is_replaced_at_each_reported_position() {
        XCTAssertEqual(
            splice("Whisper Flow beats Whisper Flow.", [
                ("Whisper Flow.", "Wispr Flow"),
                ("Whisper Flow", "Wispr Flow"),
            ]),
            "Wispr Flow beats Wispr Flow."
        )
    }

    func test_no_replacements_returns_transcript_untouched() {
        let text = "  Spacing,  kept as is. "
        XCTAssertEqual(splice(text, []), text)
    }

    // MARK: - Preflight

    func test_preflight_finds_near_term_spans() {
        XCTAssertTrue(policy.hasCandidate(in: "Tyler wants the Whisper Flow comparison."))
        XCTAssertTrue(policy.hasCandidate(in: "the SuperWhisper notes"))
        // Compound across words: "super whisper" ~ "superwhisper".
        XCTAssertTrue(policy.hasCandidate(in: "Super, Whisper!"))
    }

    func test_preflight_skips_transcripts_with_nothing_close() {
        XCTAssertFalse(policy.hasCandidate(in: "Remind me to water the plants and email the landlord."))
        XCTAssertFalse(policy.hasCandidate(in: "Can you send me the quarterly numbers before lunch?"))
        XCTAssertFalse(policy.hasCandidate(in: ""))
    }

    func test_preflight_uses_the_rescorers_minimum_similarity() {
        // Small vocabulary: size bucket 0.50, context default 0.52 → 0.52.
        XCTAssertEqual(policy.threshold, 0.52, accuracy: 1e-6)
        // "to" vs "Toby" is exactly 0.50: below the bar, so not a candidate.
        XCTAssertFalse(policy.hasCandidate(in: "Talk to you soon."))

        let large = Dictionary(uniqueKeysWithValues: (0..<120).map { ("term\($0)", "Vocab\($0)") })
        let largePolicy = VocabularyRescorePolicy(context: VocabularyBoostMapping.context(from: large)!)
        XCTAssertEqual(largePolicy.threshold, 0.60, accuracy: 1e-6)
    }

    // MARK: - Text utilities

    func test_normalize_matches_rescorer_rules() {
        XCTAssertEqual(VocabularyRescorePolicy.normalize("  Super-Whisper,  Inc.  "), "super-whisper inc")
        XCTAssertEqual(VocabularyRescorePolicy.normalize("Don't STOP"), "don't stop")
        XCTAssertEqual(VocabularyRescorePolicy.normalize("3:30 pm"), "330 pm")
    }

    func test_similarity_is_one_minus_normalized_edit_distance() {
        let kitten = Array("kitten".unicodeScalars)
        let sitting = Array("sitting".unicodeScalars)
        XCTAssertEqual(VocabularyRescorePolicy.similarity(kitten, sitting), 1 - 3.0 / 7.0, accuracy: 1e-6)
        XCTAssertTrue(VocabularyRescorePolicy.similarity(kitten, sitting, atLeast: 0.57))
        XCTAssertFalse(VocabularyRescorePolicy.similarity(kitten, sitting, atLeast: 0.58))
    }
}
