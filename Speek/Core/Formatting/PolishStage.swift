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
    func run(_ input: String) async -> String
}

/// No-op stage used when polish is disabled in Settings.
actor NullPolishStage: PolishStage {
    var isAvailable: Bool { false }
    func run(_ input: String) async -> String { input }
}
