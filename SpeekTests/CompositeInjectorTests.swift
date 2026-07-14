import XCTest
@testable import Speek

final class CompositeInjectorTests: XCTestCase {
    func test_empty_field_no_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("hello", afterPrevious: nil), "hello")
    }

    func test_after_whitespace_no_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("hello", afterPrevious: " "), "hello")
    }

    func test_after_letter_adds_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("world", afterPrevious: "o"), " world")
    }

    func test_after_period_adds_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("Hello", afterPrevious: "."), " Hello")
    }

    func test_after_comma_adds_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("then", afterPrevious: ","), " then")
    }

    func test_after_opening_quote_no_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("hello", afterPrevious: "\""), "hello")
    }

    func test_after_opening_paren_no_leading_space() {
        XCTAssertEqual(CompositeInjector.smartSpaced("note", afterPrevious: "("), "note")
    }

    // MARK: - contextFrom(prefix:)

    func test_empty_prefix_yields_empty_context() {
        let ctx = CompositeInjector.contextFrom(prefix: "")
        XCTAssertNil(ctx.immediate)
        XCTAssertNil(ctx.lastMeaningful)
    }

    func test_mid_sentence_prefix() {
        let ctx = CompositeInjector.contextFrom(prefix: "and then we went to")
        XCTAssertEqual(ctx.immediate, "o")
        XCTAssertEqual(ctx.lastMeaningful, "o")
    }

    func test_trailing_space_skipped_for_meaningful() {
        let ctx = CompositeInjector.contextFrom(prefix: "and then we went to ")
        XCTAssertEqual(ctx.immediate, " ")
        XCTAssertEqual(ctx.lastMeaningful, "o")
    }

    func test_sentence_end_detected_through_closing_quote() {
        let ctx = CompositeInjector.contextFrom(prefix: "he said \u{201C}stop.\u{201D} ")
        XCTAssertEqual(ctx.lastMeaningful, ".")
    }

    func test_closing_paren_skipped() {
        let ctx = CompositeInjector.contextFrom(prefix: "some text (like this)")
        XCTAssertEqual(ctx.lastMeaningful, "s")
    }

    func test_newline_is_immediate_but_meaningful_looks_back() {
        let ctx = CompositeInjector.contextFrom(prefix: "First line.\n")
        XCTAssertEqual(ctx.immediate, "\n")
        XCTAssertEqual(ctx.lastMeaningful, ".")
    }

    // MARK: - smartCased

    func test_keeps_capital_after_sentence_end() {
        XCTAssertEqual(CompositeInjector.smartCased("The store was closed.", afterMeaningful: "."), "The store was closed.")
        XCTAssertEqual(CompositeInjector.smartCased("Then we left.", afterMeaningful: "?"), "Then we left.")
        XCTAssertEqual(CompositeInjector.smartCased("Then we left.", afterMeaningful: "!"), "Then we left.")
    }

    func test_keeps_capital_when_context_unknown() {
        XCTAssertEqual(CompositeInjector.smartCased("The store was closed.", afterMeaningful: nil), "The store was closed.")
    }

    func test_lowercases_mid_sentence_continuation() {
        XCTAssertEqual(CompositeInjector.smartCased("The store to buy milk.", afterMeaningful: "o"), "the store to buy milk.")
    }

    func test_lowercases_after_comma() {
        XCTAssertEqual(CompositeInjector.smartCased("Which was fine.", afterMeaningful: ","), "which was fine.")
    }

    func test_preserves_capital_I_and_contractions() {
        XCTAssertEqual(CompositeInjector.smartCased("I think so.", afterMeaningful: "o"), "I think so.")
        XCTAssertEqual(CompositeInjector.smartCased("I'm not sure.", afterMeaningful: ","), "I'm not sure.")
        XCTAssertEqual(CompositeInjector.smartCased("I\u{2019}ll check.", afterMeaningful: "d"), "I\u{2019}ll check.")
    }

    func test_preserves_acronyms_and_interior_capitals() {
        XCTAssertEqual(CompositeInjector.smartCased("PDF export works.", afterMeaningful: "e"), "PDF export works.")
        XCTAssertEqual(CompositeInjector.smartCased("McDonald was there.", afterMeaningful: "d"), "McDonald was there.")
    }

    func test_already_lowercase_unchanged() {
        XCTAssertEqual(CompositeInjector.smartCased("the store", afterMeaningful: "o"), "the store")
    }

    func test_empty_insert_unchanged() {
        XCTAssertEqual(CompositeInjector.smartCased("", afterMeaningful: "o"), "")
    }

    // MARK: - casing + spacing composition (order used by insert())

    func test_continuation_gets_lowercase_and_space() {
        let ctx = CompositeInjector.contextFrom(prefix: "and then we went to")
        var adjusted = CompositeInjector.smartCased("The store.", afterMeaningful: ctx.lastMeaningful)
        adjusted = CompositeInjector.smartSpaced(adjusted, afterPrevious: ctx.immediate)
        XCTAssertEqual(adjusted, " the store.")
    }

    func test_new_sentence_keeps_capital_and_gets_space() {
        let ctx = CompositeInjector.contextFrom(prefix: "We finished early.")
        var adjusted = CompositeInjector.smartCased("Then we left.", afterMeaningful: ctx.lastMeaningful)
        adjusted = CompositeInjector.smartSpaced(adjusted, afterPrevious: ctx.immediate)
        XCTAssertEqual(adjusted, " Then we left.")
    }
}
