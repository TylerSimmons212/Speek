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
}
