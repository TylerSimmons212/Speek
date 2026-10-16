import FluidAudio
import XCTest
@testable import Speek

final class VocabularyBoostMappingTests: XCTestCase {
    private func terms(_ replacements: [String: String]) -> [(text: String, aliases: [String]?)] {
        VocabularyBoostMapping.terms(from: replacements).map { ($0.text, $0.aliases) }
    }

    func test_empty_vocabulary_disables_boosting() {
        XCTAssertTrue(VocabularyBoostMapping.terms(from: [:]).isEmpty)
        XCTAssertNil(VocabularyBoostMapping.context(from: [:]))
    }

    func test_replacement_is_canonical_text_and_source_is_alias() {
        let out = terms(["whisper flow": "Wispr Flow"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Wispr Flow")
        XCTAssertEqual(out[0].aliases, ["whisper flow"])
    }

    func test_sources_sharing_a_replacement_become_one_term() {
        let out = terms([
            "whisper flow": "Wispr Flow",
            "wisper flo": "Wispr Flow",
            "Whisper Flow": "Wispr Flow",
        ])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Wispr Flow")
        // Sorted; "whisper flow" collapses into "Whisper Flow" (first in sort order).
        XCTAssertEqual(out[0].aliases, ["Whisper Flow", "wisper flo"])
    }

    func test_casing_only_entry_has_no_alias() {
        let out = terms(["github": "GitHub"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "GitHub")
        XCTAssertNil(out[0].aliases)
    }

    func test_terms_are_sorted_by_canonical_text() {
        let out = terms([
            "cube netties": "Kubernetes",
            "speak": "Speek",
            "fluid audio": "FluidAudio",
        ])
        XCTAssertEqual(out.map(\.text), ["FluidAudio", "Kubernetes", "Speek"])
    }

    func test_whitespace_is_trimmed_from_both_sides() {
        let out = terms([" cube netties ": "  Kubernetes\n"])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].text, "Kubernetes")
        XCTAssertEqual(out[0].aliases, ["cube netties"])
    }

    func test_short_terms_stay_rule_stage_only() {
        // Short keywords over-fire on ordinary English in the CTC spotter.
        XCTAssertNil(VocabularyBoostMapping.context(from: ["a w s": "AWS", "too": "2"]))
    }

    func test_snippet_expansions_are_not_boosted() {
        let replacements = [
            "my address": "1 Infinite Loop, Cupertino, California 95014",
            "sig": "Thanks so much and talk soon",
            "one two three": "12345",
            "long one": String(repeating: "x", count: VocabularyBoostMapping.maxTermLength + 1),
        ]
        XCTAssertNil(VocabularyBoostMapping.context(from: replacements))
    }

    func test_boostable_and_unboostable_entries_mix() {
        let out = terms([
            "a w s": "AWS",
            "speak": "Speek",
            "my address": "1 Infinite Loop, Cupertino, California 95014",
        ])
        XCTAssertEqual(out.map(\.text), ["Speek"])
        XCTAssertEqual(out[0].aliases, ["speak"])
    }

    func test_multi_word_names_up_to_the_word_limit_are_boosted() {
        XCTAssertTrue(VocabularyBoostMapping.isBoostable("Wispr Flow"))
        XCTAssertTrue(VocabularyBoostMapping.isBoostable("Bank of New Zealand"))
        XCTAssertFalse(VocabularyBoostMapping.isBoostable("The Bank of New Zealand"))
    }

    func test_context_carries_terms_untokenized() {
        // Token IDs are filled in by VocabularyBoostingSession with the CTC
        // tokenizer that ships beside the downloaded encoder.
        let context = VocabularyBoostMapping.context(from: ["speak": "Speek"])
        XCTAssertEqual(context?.terms.count, 1)
        XCTAssertNil(context?.terms.first?.ctcTokenIds)
    }

    func test_booster_stays_off_without_boostable_terms() async {
        // No boostable term: returns without downloading or loading the CTC encoder.
        let booster = VocabularyBooster()
        await booster.update(replacements: ["a w s": "AWS"])
        let active = await booster.isActive
        XCTAssertFalse(active)
        let boost = await booster.active()
        XCTAssertNil(boost)
    }
}
