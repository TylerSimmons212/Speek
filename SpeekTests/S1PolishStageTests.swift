import XCTest
@testable import Speek

/// Integration tests against the real s1-mini weights. Skipped automatically
/// on machines that haven't downloaded the model (~484 MB) — everything
/// model-independent (prompt format, chunking, budget) lives in S1PromptTests.
final class S1PolishStageTests: XCTestCase {
    private func requireModel() throws {
        try XCTSkipUnless(
            S1ModelStore.isModelPresent,
            "s1-mini weights not present — run the app once (or Settings → AI polish → Download) to fetch them"
        )
    }

    func test_resolves_self_correction_and_strips_fillers() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run(
            "so um i need to like send the the report by uh friday no wait make that thursday"
        )
        let lowered = out.lowercased()
        XCTAssertTrue(lowered.contains("thursday"), "kept the corrected day — got: \(out)")
        XCTAssertFalse(lowered.contains("friday"), "dropped the retracted day — got: \(out)")
        XCTAssertFalse(lowered.contains("um"), "stripped fillers — got: \(out)")
    }

    func test_formats_spoken_date_and_time() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run(
            "the meeting is at three thirty pm on may sixth"
        )
        XCTAssertTrue(out.contains("3:30"), "got: \(out)")
        XCTAssertTrue(out.contains("May 6"), "got: \(out)")
    }

    func test_clean_input_passes_through() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run("Hello, world. How are you?")
        XCTAssertEqual(out, "Hello, world. How are you?")
    }
}
