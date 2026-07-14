import XCTest
@testable import Speek

final class TypingInjectorTests: XCTestCase {

    // MARK: - Basic chunking

    func testEmptyInputYieldsNoRanges() {
        XCTAssertTrue(TypingInjector.chunkRanges(for: [], maxLength: 200).isEmpty)
    }

    func testShortTextIsSingleChunk() {
        let units = Array("hello world".utf16)
        let ranges = TypingInjector.chunkRanges(for: units, maxLength: 200)
        XCTAssertEqual(ranges, [0..<units.count])
    }

    func testExactMultipleSplitsEvenly() {
        let units = Array(String(repeating: "a", count: 400).utf16)
        let ranges = TypingInjector.chunkRanges(for: units, maxLength: 200)
        XCTAssertEqual(ranges, [0..<200, 200..<400])
    }

    func testRangesCoverInputExactlyOnce() {
        let units = Array(String(repeating: "abc😀", count: 100).utf16)
        let ranges = TypingInjector.chunkRanges(for: units, maxLength: 7)
        // Contiguous, non-overlapping, complete coverage.
        var expectedStart = 0
        for range in ranges {
            XCTAssertEqual(range.lowerBound, expectedStart)
            expectedStart = range.upperBound
        }
        XCTAssertEqual(expectedStart, units.count)
    }

    // MARK: - Surrogate-pair safety

    func testSurrogatePairAtBoundaryIsNotSplit() {
        // "aaa…a😀" arranged so the emoji's high surrogate lands exactly on
        // the chunk boundary. 😀 = U+1F600 = D83D DE00 (2 UTF-16 units).
        let text = String(repeating: "a", count: 199) + "😀"
        let units = Array(text.utf16)
        XCTAssertEqual(units.count, 201)

        let ranges = TypingInjector.chunkRanges(for: units, maxLength: 200)
        XCTAssertEqual(ranges.count, 2)
        // Boundary must back off to 199 so D83D DE00 stay together.
        XCTAssertEqual(ranges[0], 0..<199)
        XCTAssertEqual(ranges[1], 199..<201)
        XCTAssertTrue(TypingInjector.isHighSurrogate(units[199]))
        XCTAssertTrue(TypingInjector.isLowSurrogate(units[200]))
    }

    func testEveryChunkDecodesAsValidUTF16() {
        // All-emoji text stresses boundaries at every chunk edge.
        let text = String(repeating: "😀🎤🗣️", count: 60)
        let units = Array(text.utf16)
        for maxLen in [2, 3, 5, 20, 200] {
            let ranges = TypingInjector.chunkRanges(for: units, maxLength: maxLen)
            for range in ranges {
                let chunk = Array(units[range])
                let decoded = String(decoding: chunk, as: UTF16.self)
                // A split pair decodes to U+FFFD REPLACEMENT CHARACTER.
                XCTAssertFalse(
                    decoded.unicodeScalars.contains("\u{FFFD}"),
                    "chunk \(range) at maxLen \(maxLen) split a surrogate pair"
                )
            }
        }
    }

    func testReassembledChunksEqualOriginal() {
        let text = "Send 💰 to Zoë — 面白い test 🇺🇸 done."
        let units = Array(text.utf16)
        for maxLen in [2, 4, 7, 200] {
            let ranges = TypingInjector.chunkRanges(for: units, maxLength: maxLen)
            let reassembled = ranges.flatMap { Array(units[$0]) }
            XCTAssertEqual(String(decoding: reassembled, as: UTF16.self), text)
        }
    }

    func testLoneSurrogatePassesThrough() {
        // Malformed input (lone high surrogate, no low) must not hang or drop
        // units — the backoff only triggers for a genuine high+low pair.
        let units: [UInt16] = Array(String(repeating: "a", count: 199).utf16) + [0xD83D, 0x0061]
        let ranges = TypingInjector.chunkRanges(for: units, maxLength: 200)
        XCTAssertEqual(ranges.flatMap { Array(units[$0]) }.count, units.count)
        // No pair at the boundary (units[200] is 'a'), so no backoff.
        XCTAssertEqual(ranges[0], 0..<200)
    }

    // MARK: - Surrogate classification

    func testSurrogateClassification() {
        XCTAssertTrue(TypingInjector.isHighSurrogate(0xD800))
        XCTAssertTrue(TypingInjector.isHighSurrogate(0xDBFF))
        XCTAssertFalse(TypingInjector.isHighSurrogate(0xDC00))
        XCTAssertTrue(TypingInjector.isLowSurrogate(0xDC00))
        XCTAssertTrue(TypingInjector.isLowSurrogate(0xDFFF))
        XCTAssertFalse(TypingInjector.isLowSurrogate(0xD800))
        XCTAssertFalse(TypingInjector.isHighSurrogate(0x0041)) // 'A'
        XCTAssertFalse(TypingInjector.isLowSurrogate(0x0041))
    }
}
