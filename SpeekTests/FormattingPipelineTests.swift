import XCTest
@testable import Speek

final class FormattingPipelineTests: XCTestCase {
    func test_runs_polish_on_every_dictation_when_available() async {
        let pipeline = FormattingPipeline(
            rule: RuleStage(),
            polish: StubPolish(transform: { $0 + " [polished]" })
        )
        let result = await pipeline.run("um hello world")
        // Rule pass strips the filler first, then polish runs.
        XCTAssertEqual(result, "Hello world [polished]")
    }

    func test_ships_rule_output_when_polish_unavailable() async {
        let pipeline = FormattingPipeline(
            rule: RuleStage(),
            polish: StubPolish(transform: { _ in fatalError("should not run") }, isAvailable: false)
        )
        let result = await pipeline.run("um hello world")
        XCTAssertEqual(result, "Hello world")
    }

    func test_skips_polish_when_rule_output_is_empty() async {
        let pipeline = FormattingPipeline(
            rule: RuleStage(),
            polish: StubPolish(transform: { _ in fatalError("should not run") })
        )
        // Filler-only dictation — rule pass reduces it to nothing.
        let result = await pipeline.run("um uh")
        XCTAssertEqual(result, "")
    }

    func test_passes_style_through_to_polish() async {
        let polish = StubPolish(transform: { $0 })
        let pipeline = FormattingPipeline(rule: RuleStage(), polish: polish)
        let style = PolishStyle(styling: .semiCasual, structure: .lists, context: .email)
        _ = await pipeline.run("hello", style: style)
        let received = await polish.lastStyle
        XCTAssertEqual(received, style)
    }

    func test_defaults_to_standard_style() async {
        let polish = StubPolish(transform: { $0 })
        let pipeline = FormattingPipeline(rule: RuleStage(), polish: polish)
        _ = await pipeline.run("hello")
        let received = await polish.lastStyle
        XCTAssertEqual(received, .standard)
    }

    func test_polish_can_legitimately_return_empty() async {
        let pipeline = FormattingPipeline(
            rule: RuleStage(),
            polish: StubPolish(transform: { _ in "" })
        )
        let result = await pipeline.run("hello")
        XCTAssertEqual(result, "")
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
    private(set) var lastStyle: PolishStyle?
    func run(_ input: String, style: PolishStyle) async -> String {
        lastStyle = style
        return transform(input)
    }
}
