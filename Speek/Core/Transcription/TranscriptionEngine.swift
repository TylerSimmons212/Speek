import Foundation

protocol TranscriptionEngine: Sendable {
    /// Transcribes the full PCM buffer (16kHz mono Float32) and returns a finalized transcript.
    /// Parakeet emits punctuation; the returned string is "raw" but mostly readable.
    func transcribe(samples: [Float]) async throws -> String
}

/// Stand-in used when the real engine failed to load (e.g. first launch with
/// no network for the model download). Keeps the full UI alive — an
/// LSUIElement app with no menu bar item is invisible and unquittable — and
/// surfaces the failure through the session's normal error path whenever the
/// user tries to dictate.
struct UnavailableTranscriptionEngine: TranscriptionEngine {
    struct Unavailable: LocalizedError {
        var errorDescription: String? {
            "Transcription model isn't loaded — check your internet connection and relaunch Speek."
        }
    }

    func transcribe(samples: [Float]) async throws -> String {
        throw Unavailable()
    }
}
