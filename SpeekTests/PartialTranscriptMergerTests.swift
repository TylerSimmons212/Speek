import XCTest
@testable import Speek

final class PartialTranscriptMergerTests: XCTestCase {

    func testFirstDecodeDisplaysAsIs() {
        var merger = PartialTranscriptMerger()
        XCTAssertEqual(merger.merge("hello world"), "hello world")
    }

    func testGrowingDecodesExtendDisplay() {
        var merger = PartialTranscriptMerger()
        _ = merger.merge("the quick")
        _ = merger.merge("the quick brown fox")
        XCTAssertEqual(merger.merge("the quick brown fox jumps over"), "the quick brown fox jumps over")
    }

    func testLockedRegionSurvivesShortGlitchDecode() {
        var merger = PartialTranscriptMerger(churnTail: 2)
        _ = merger.merge("the quick brown fox jumps")
        // Locked: "the quick brown". A transient glitch decode much shorter
        // than the lock cannot erase locked words; the unlocked tail may
        // momentarily drop (the next full re-decode restores it).
        let display = merger.merge("the quick")
        XCTAssertEqual(display, "the quick brown")
    }

    func testChurnTailMayRewrite() {
        var merger = PartialTranscriptMerger(churnTail: 2)
        _ = merger.merge("i want to meet on monday")
        // Trailing words are unlocked — the decoder can revise them.
        let display = merger.merge("i want to meet on tuesday morning")
        XCTAssertEqual(display, "i want to meet on tuesday morning")
    }

    func testLockedWordsDoNotFlicker() {
        var merger = PartialTranscriptMerger(churnTail: 2)
        _ = merger.merge("send the report to sarah please today")
        // With churnTail 2, "send the report to sarah" is locked. A decode
        // that rewrites an early locked word must not change the display's
        // locked region.
        let display = merger.merge("sent the report to sarah please today okay")
        XCTAssertTrue(display.hasPrefix("send the report to sarah"), "locked words flickered: \(display)")
        XCTAssertTrue(display.hasSuffix("okay"))
    }

    func testDisagreementGraftsTailBeyondLockedLength() {
        var merger = PartialTranscriptMerger(churnTail: 0)
        _ = merger.merge("alpha beta gamma")           // all locked
        let display = merger.merge("alpha bravo gamma delta")
        // "bravo" contradicts locked "beta" → locked wins, tail grafts on.
        XCTAssertEqual(display, "alpha beta gamma delta")
    }

    func testEmptyDecodeKeepsDisplay() {
        var merger = PartialTranscriptMerger()
        _ = merger.merge("hello there")
        XCTAssertEqual(merger.merge(""), "hello there")
    }

    func testWhitespaceOnlyDecodeKeepsDisplay() {
        var merger = PartialTranscriptMerger()
        _ = merger.merge("hello there")
        XCTAssertEqual(merger.merge("   \n "), "hello there")
    }

    func testZeroChurnTailLocksEverything() {
        var merger = PartialTranscriptMerger(churnTail: 0)
        _ = merger.merge("one two three")
        XCTAssertEqual(merger.merge("uno dos tres"), "one two three")
    }
}
