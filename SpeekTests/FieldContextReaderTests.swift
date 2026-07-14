import XCTest
@testable import Speek

final class FieldContextReaderTests: XCTestCase {

    // MARK: - split(prefix:)

    func test_mid_sentence_prefix_is_all_fragment() {
        let (preceding, fragment) = FieldContextReader.split(prefix: "and then we went to")
        XCTAssertEqual(preceding, "")
        XCTAssertEqual(fragment, "and then we went to")
    }

    func test_completed_sentence_yields_empty_fragment() {
        let (preceding, fragment) = FieldContextReader.split(prefix: "We finished early. ")
        XCTAssertEqual(preceding, "We finished early.")
        XCTAssertEqual(fragment, "")
    }

    func test_fragment_after_terminator() {
        let (preceding, fragment) = FieldContextReader.split(prefix: "First thought. and then we")
        XCTAssertEqual(preceding, "First thought.")
        XCTAssertEqual(fragment, "and then we")
    }

    func test_newline_terminates_fragment() {
        let (preceding, fragment) = FieldContextReader.split(prefix: "Line one\nline two unfinished")
        XCTAssertEqual(preceding, "Line one")
        XCTAssertEqual(fragment, "line two unfinished")
    }

    func test_oversized_fragment_demoted_to_preceding() {
        let long = String(repeating: "word ", count: 100) // 500 chars, no terminator
        let (preceding, fragment) = FieldContextReader.split(prefix: long)
        XCTAssertEqual(fragment, "")
        XCTAssertFalse(preceding.isEmpty)
        XCTAssertLessThanOrEqual(preceding.count, FieldContextReader.maxPrecedingLength)
    }

    func test_preceding_is_capped() {
        let prefix = String(repeating: "a", count: 800) + ". tail"
        let (preceding, fragment) = FieldContextReader.split(prefix: prefix)
        XCTAssertEqual(fragment, "tail")
        XCTAssertLessThanOrEqual(preceding.count, FieldContextReader.maxPrecedingLength)
    }

    // MARK: - suffixAfterFragment

    func test_exact_prefix_yields_suffix() {
        XCTAssertEqual(
            CompositeInjector.suffixAfterFragment(fragment: "and then we went to", merged: "and then we went to the store."),
            " the store."
        )
    }

    func test_trailing_space_fragment_tolerated() {
        XCTAssertEqual(
            CompositeInjector.suffixAfterFragment(fragment: "went to ", merged: "went to the store."),
            "the store."
        )
    }

    func test_corrected_fragment_yields_nil() {
        XCTAssertNil(
            CompositeInjector.suffixAfterFragment(fragment: "and then we goes to", merged: "and then we went to the store.")
        )
    }

    func test_fragment_only_output_yields_empty_suffix() {
        XCTAssertEqual(
            CompositeInjector.suffixAfterFragment(fragment: "hello", merged: "hello"),
            ""
        )
    }
}
