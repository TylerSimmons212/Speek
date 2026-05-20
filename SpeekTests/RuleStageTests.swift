import XCTest
@testable import Speek

final class RuleStageTests: XCTestCase {
    let stage = RuleStage()

    func test_strips_um_and_uh_with_surrounding_whitespace() {
        XCTAssertEqual(stage.run("Well um I think uh this works"), "Well I think this works")
    }

    func test_capitalizes_first_word_of_input() {
        XCTAssertEqual(stage.run("hello world."), "Hello world.")
    }

    func test_capitalizes_after_period() {
        XCTAssertEqual(stage.run("First sentence. second sentence."), "First sentence. Second sentence.")
    }

    func test_collapses_repeated_words() {
        XCTAssertEqual(stage.run("I I think we should should go"), "I think we should go")
    }

    func test_applies_custom_replacements_case_insensitive() {
        let s = RuleStage(customReplacements: ["github": "GitHub", "tylersimmons212": "Tyler"])
        XCTAssertEqual(s.run("send this to tylersimmons212 on github"), "Send this to Tyler on GitHub")
    }

    func test_preserves_existing_punctuation_from_parakeet() {
        XCTAssertEqual(stage.run("Hello, world. How are you?"), "Hello, world. How are you?")
    }

    func test_empty_string_returns_empty() {
        XCTAssertEqual(stage.run(""), "")
    }

    func test_resolves_single_word_correction_actually() {
        XCTAssertEqual(stage.run("lunch on Friday, actually Saturday"), "Lunch on Saturday")
    }

    func test_resolves_single_word_correction_i_mean() {
        XCTAssertEqual(stage.run("call John, I mean Mary"), "Call Mary")
    }

    func test_resolves_single_word_correction_no_wait() {
        XCTAssertEqual(stage.run("meet at three, no wait, four"), "Meet at four")
    }

    func test_resolves_full_clause_rewrite() {
        XCTAssertEqual(
            stage.run("send it to John, actually send it to Mary"),
            "Send it to Mary"
        )
    }

    func test_flags_ambiguous_correction() {
        let result = stage.process("Friday, actually next Saturday")
        XCTAssertTrue(result.possibleAmbiguousCorrection)
        // Text is left unchanged so the LLM can decide.
        XCTAssertEqual(result.text, "Friday, actually next Saturday")
    }

    func test_non_correction_text_is_not_flagged() {
        let result = stage.process("hello world")
        XCTAssertFalse(result.possibleAmbiguousCorrection)
    }

    // MARK: Voice commands

    func test_voice_command_period() {
        XCTAssertEqual(stage.run("this is the end period"), "This is the end.")
    }

    func test_voice_command_comma() {
        XCTAssertEqual(stage.run("first comma second comma third"), "First, second, third")
    }

    func test_voice_command_new_line() {
        XCTAssertEqual(stage.run("line one new line line two"), "Line one\nLine two")
    }

    func test_voice_command_question_mark() {
        XCTAssertEqual(stage.run("are you there question mark"), "Are you there?")
    }

    // MARK: Number formatting

    func test_number_year_style() {
        XCTAssertEqual(stage.run("the year is twenty twenty four"), "The year is 2024")
    }

    func test_number_hundreds() {
        XCTAssertEqual(stage.run("there are one hundred twenty three apples"), "There are 123 apples")
    }

    func test_currency_dollars() {
        XCTAssertEqual(stage.run("it costs five hundred dollars"), "It costs $500")
    }

    func test_date_ordinal() {
        XCTAssertEqual(stage.run("meet on may fifth"), "Meet on May 5")
    }

    func test_decimal_point() {
        XCTAssertEqual(stage.run("pi is three point one four"), "Pi is 3.14")
    }
}
