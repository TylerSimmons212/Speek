import XCTest
@testable import Speek

final class FormattingPipelineTests: XCTestCase {
    func test_runs_rule_stage_then_fm_stage() async {
        let rule = RuleStage()
        let fm = StubPolish(transform: { $0 + " [polished]" })
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("um hello world")
        XCTAssertEqual(result, "Hello world [polished]")
    }

    func test_skips_fm_when_unavailable() async {
        let rule = RuleStage()
        let fm = StubPolish(transform: { _ in fatalError("should not run") }, isAvailable: false)
        let pipeline = FormattingPipeline(rule: rule, polish: fm)

        let result = await pipeline.run("um hello world")
        XCTAssertEqual(result, "Hello world")
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
