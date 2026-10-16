import XCTest
@testable import Speek

final class SystemTrackSpoolTests: XCTestCase {
    private func read(_ source: MappedPCM16Source, offset: Int, count: Int, fill: Float = -9) -> [Float] {
        var out = [Float](repeating: fill, count: count)
        out.withUnsafeMutableBufferPointer { buffer in
            try? source.copySamples(into: buffer.baseAddress!, offset: offset, count: count)
        }
        return out
    }

    func test_round_trips_samples_across_appends_within_int16_precision() throws {
        let spool = try XCTUnwrap(SystemTrackSpool())
        let first: [Float] = [0, 0.5, -0.5, 0.999]
        let second: [Float] = [-1, 0.25, 0.001]
        spool.append(first)
        spool.append([])
        spool.append(second)
        XCTAssertEqual(spool.sampleCount, 7)

        let source = try XCTUnwrap(spool.finish())
        XCTAssertEqual(source.sampleCount, 7)
        for (got, want) in zip(read(source, offset: 0, count: 7), first + second) {
            XCTAssertEqual(got, want, accuracy: 1.0 / 16_000)
        }
    }

    func test_out_of_range_samples_clip_instead_of_wrapping() throws {
        let spool = try XCTUnwrap(SystemTrackSpool())
        spool.append([1.7, -2.4])
        let source = try XCTUnwrap(spool.finish())
        let samples = read(source, offset: 0, count: 2)
        XCTAssertEqual(samples[0], 1, accuracy: 0.001)
        XCTAssertEqual(samples[1], -1, accuracy: 0.001)
    }

    func test_reads_past_the_end_copy_only_what_exists() throws {
        let spool = try XCTUnwrap(SystemTrackSpool())
        spool.append([0.1, 0.2, 0.3])
        let source = try XCTUnwrap(spool.finish())

        let partial = read(source, offset: 2, count: 3)
        XCTAssertEqual(partial[0], 0.3, accuracy: 0.001)
        XCTAssertEqual(Array(partial.dropFirst()), [-9, -9], "untouched past the end")
        XCTAssertEqual(read(source, offset: 10, count: 2), [-9, -9])
    }

    func test_empty_session_has_nothing_to_diarize() throws {
        let spool = try XCTUnwrap(SystemTrackSpool())
        XCTAssertNil(spool.finish())
    }

    func test_temp_file_is_deleted_with_the_spool() throws {
        var spool: SystemTrackSpool? = try XCTUnwrap(SystemTrackSpool())
        spool?.append([0.1])
        let url = try XCTUnwrap(spool?.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        spool = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test_storage_is_two_bytes_per_sample() throws {
        let spool = try XCTUnwrap(SystemTrackSpool())
        spool.append([Float](repeating: 0.1, count: 16_000))
        _ = spool.finish()
        let size = try FileManager.default.attributesOfItem(atPath: spool.url.path)[.size] as? Int
        XCTAssertEqual(size, 32_000)
    }
}
