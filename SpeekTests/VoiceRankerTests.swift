import XCTest
@testable import Speek

final class VoiceRankerTests: XCTestCase {

    private func voice(
        _ id: String, lang: String, quality: Int, name: String,
        novelty: Bool = false, personal: Bool = false
    ) -> VoiceRanker.Candidate {
        VoiceRanker.Candidate(
            identifier: id, language: lang, quality: quality, name: name,
            isNovelty: novelty, isPersonalVoice: personal
        )
    }

    func test_premium_beats_enhanced_same_locale() {
        let best = VoiceRanker.best(from: [
            voice("ava-enhanced", lang: "en-US", quality: 2, name: "Ava (Enhanced)"),
            voice("ava-premium", lang: "en-US", quality: 3, name: "Ava (Premium)"),
            voice("samantha", lang: "en-US", quality: 1, name: "Samantha")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "ava-premium")
    }

    func test_exact_locale_beats_other_region_of_same_language() {
        // Locale fit dominates quality: a standard en-US voice wins over a
        // premium en-GB one for an en-US user (right accent > shinier voice).
        let best = VoiceRanker.best(from: [
            voice("serena-premium", lang: "en-GB", quality: 3, name: "Serena (Premium)"),
            voice("samantha", lang: "en-US", quality: 1, name: "Samantha")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "samantha")
    }

    func test_same_language_other_region_beats_different_language() {
        let best = VoiceRanker.best(from: [
            voice("anna-premium", lang: "de-DE", quality: 3, name: "Anna (Premium)"),
            voice("karen", lang: "en-AU", quality: 1, name: "Karen")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "karen")
    }

    func test_novelty_and_personal_voices_never_auto_picked() {
        let best = VoiceRanker.best(from: [
            voice("zarvox", lang: "en-US", quality: 3, name: "Zarvox", novelty: true),
            voice("my-voice", lang: "en-US", quality: 3, name: "My Voice", personal: true),
            voice("samantha", lang: "en-US", quality: 1, name: "Samantha")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "samantha")
    }

    func test_no_language_match_falls_back_to_best_quality_anywhere() {
        let best = VoiceRanker.best(from: [
            voice("kyoko", lang: "ja-JP", quality: 1, name: "Kyoko"),
            voice("anna-premium", lang: "de-DE", quality: 3, name: "Anna (Premium)")
        ], preferredLanguage: "fr-FR")
        XCTAssertEqual(best?.identifier, "anna-premium")
    }

    func test_ties_broken_alphabetically_for_stability() {
        let best = VoiceRanker.best(from: [
            voice("zoe-premium", lang: "en-US", quality: 3, name: "Zoe (Premium)"),
            voice("ava-premium", lang: "en-US", quality: 3, name: "Ava (Premium)")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "ava-premium")
    }

    func test_empty_or_all_excluded_returns_nil() {
        XCTAssertNil(VoiceRanker.best(from: [], preferredLanguage: "en-US"))
        XCTAssertNil(VoiceRanker.best(from: [
            voice("zarvox", lang: "en-US", quality: 3, name: "Zarvox", novelty: true)
        ], preferredLanguage: "en-US"))
    }

    func test_case_insensitive_locale_match() {
        let best = VoiceRanker.best(from: [
            voice("samantha", lang: "en-us", quality: 1, name: "Samantha"),
            voice("karen", lang: "en-AU", quality: 2, name: "Karen")
        ], preferredLanguage: "en-US")
        XCTAssertEqual(best?.identifier, "samantha")
    }

    func test_primary_code_handles_dashes_and_underscores() {
        XCTAssertEqual(VoiceRanker.primaryCode("en-US"), "en")
        XCTAssertEqual(VoiceRanker.primaryCode("en_US"), "en")
        XCTAssertEqual(VoiceRanker.primaryCode("de"), "de")
    }
}
