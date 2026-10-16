import Foundation

/// Abstraction over the LLM polish stage so the pipeline can be tested with
/// stubs. `S1PolishStage` is the production implementation (s1-mini via
/// llama.cpp).
///
/// Contract: implementations fail open — any load or decode error returns the
/// input unchanged, because a raw transcript always beats a lost one. An empty
/// return for non-empty input is a *valid* result (a filler-only dictation
/// normalizes to nothing).
protocol PolishStage: Sendable, Actor {
    var isAvailable: Bool { get async }
    func run(_ input: String, style: PolishStyle) async -> String
}

extension PolishStage {
    func run(_ input: String) async -> String {
        await run(input, style: .standard)
    }
}

/// How the polish stage should shape its output. The axes and their values
/// are exactly s1-mini's trained control-line vocabulary; the model card
/// warns that anything outside these sets can produce garbled output, so
/// they're closed enums and never free text.
struct PolishStyle: Equatable, Sendable {
    enum Styling: String, CaseIterable, Sendable {
        /// All lowercase, apostrophes stripped.
        case casual
        /// Keeps the speaker's phrasing; capitalizes "I".
        case semiCasual = "semi-casual"
        /// Standard written English, contractions kept.
        case semiFormal = "semi-formal"
        /// Like semi-formal, with contractions expanded.
        case formal
    }

    enum Structure: String, CaseIterable, Sendable {
        case prose
        /// Turns enumerated content (3+ items) into Markdown bullets.
        case lists
    }

    enum Context: String, CaseIterable, Sendable {
        case general
        /// Lays out greeting, body, and sign-off as separate blocks.
        case email
    }

    var styling: Styling = .semiFormal
    var structure: Structure = .prose
    var context: Context = .general

    /// Standard written English prose: the model card's recommended default.
    static let standard = PolishStyle()
}

/// No-op stage used when polish is disabled in Settings.
actor NullPolishStage: PolishStage {
    var isAvailable: Bool { false }
    func run(_ input: String, style: PolishStyle) async -> String { input }
}
