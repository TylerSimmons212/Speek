import XCTest
@testable import Speek

final class FormattingPipelineTests: XCTestCase {
    func test_skips_fm_when_no_correction_markers() async {
        // Non-ambiguous input — FM stage should NOT run.
        let rule = RuleStage()
        let fm = StubPolish(transform: { _ in fatalError("should not run") })
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("um hello world")
        XCTAssertEqual(result, "Hello world")
    }

    func test_skips_fm_when_rule_resolves_correction_cleanly() async {
        // Clean word-swap correction — RuleStage handles it, FM should NOT run.
        let rule = RuleStage()
        let fm = StubPolish(transform: { _ in fatalError("should not run") })
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("lunch on Friday, actually Saturday")
        XCTAssertEqual(result, "Lunch on Saturday")
    }

    func test_falls_through_to_fm_when_correction_ambiguous() async {
        // Two-word Y with one-word X → ambiguous → FM runs.
        let rule = RuleStage()
        let fm = StubPolish(transform: { $0 + " [polished]" })
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("Friday, actually next Saturday")
        XCTAssertEqual(result, "Friday, actually next Saturday [polished]")
    }

    func test_skips_fm_when_unavailable() async {
        let rule = RuleStage()
        let fm = StubPolish(transform: { _ in fatalError("should not run") }, isAvailable: false)
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("Friday, actually next Saturday")
        // Ambiguous, but polish stage unavailable — return rule output unchanged.
        XCTAssertEqual(result, "Friday, actually next Saturday")
    }
}

actor StubPolish: PolishStage {
    let transform: @Sendable (String) -> String
    let _isAvailable: Bool
    init(transform: @escaping @Sendable (String) -> String, isAvailable: Bool = true) {
        self.transform = transform
        self._isAvailable = isAvailable
    }
    var isAvailable: Bool { _isAvailable }
    func run(_ input: String) async -> String { transform(input) }
}
