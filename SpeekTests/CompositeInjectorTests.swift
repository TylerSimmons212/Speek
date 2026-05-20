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
}
