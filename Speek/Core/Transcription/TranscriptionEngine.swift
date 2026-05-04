import Foundation

protocol TranscriptionEngine: Sendable {
    /// Transcribes the full PCM buffer (16kHz mono Float32) and returns a finalized transcript.
    /// Parakeet emits punctuation; the returned string is "raw" but mostly readable.
    func transcribe(samples: [Float]) async throws -> String
}
