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

    func test_email_context_lays_out_a_whole_email() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run(
            "hi sarah thanks for sending the proposal over it looks great lets set up a call next week best tyler",
            style: PolishStyle(context: .email)
        )
        XCTAssertTrue(out.hasPrefix("Hi Sarah,\n"), "greeting on its own line — got: \(out)")
        XCTAssertTrue(out.contains("\n\nBest,"), "sign-off block — got: \(out)")
    }

    /// Mail is where people dictate replies and mid-draft edits; email
    /// context must not invent a greeting or sign-off around one sentence.
    func test_email_context_leaves_single_sentence_alone() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run(
            "can you send me the updated deck by friday so i can review it before the board meeting",
            style: PolishStyle(context: .email)
        )
        XCTAssertFalse(out.contains("\n"), "no layout added — got: \(out)")
        XCTAssertTrue(out.hasPrefix("Can you send me"), "got: \(out)")
    }

    func test_clean_input_passes_through() async throws {
        try requireModel()
        let out = await S1PolishStage.shared.run("Hello, world. How are you?")
        XCTAssertEqual(out, "Hello, world. How are you?")
    }
}
