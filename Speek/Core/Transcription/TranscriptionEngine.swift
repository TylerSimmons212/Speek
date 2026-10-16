import Foundation

protocol TranscriptionEngine: Sendable {
    /// Transcribes the full PCM buffer (16kHz mono Float32) and returns a finalized transcript.
    /// Parakeet emits punctuation; the returned string is "raw" but mostly readable.
    func transcribe(samples: [Float]) async throws -> String

    /// The same final decode, plus where each word sits in `samples`.
    /// Meeting mode uses the timings to split a segment where the speaker
    /// changes mid-window.
    func transcribeWithWordTimings(samples: [Float]) async throws -> TimedTranscript
}

extension TranscriptionEngine {
    /// Engines without timings return the text alone; segments then stay whole.
    func transcribeWithWordTimings(samples: [Float]) async throws -> TimedTranscript {
        TimedTranscript(text: try await transcribe(samples: samples), decodedWords: [])
    }
}

/// A transcript and the timing of each of its words.
struct TimedTranscript: Sendable, Equatable {
    struct Word: Sendable, Equatable {
        /// Seconds from the start of the decoded audio.
        var start: TimeInterval
        var end: TimeInterval
    }

    let text: String
    /// One entry per whitespace-separated word of `text`, in order, or empty
    /// when timings are unavailable.
    let words: [Word]

    /// Pairs `text` with timings for the decoder's words. When a post-pass
    /// rewrote the text so the word counts differ (vocabulary rescoring can
    /// merge or split words), each text word borrows the timing of the
    /// decoder word at the same relative position.
    init(text: String, decodedWords: [Word]) {
        self.text = text
        let count = Self.wordCount(text)
        if decodedWords.isEmpty || count == 0 {
            words = []
        } else if decodedWords.count == count {
            words = decodedWords
        } else {
            words = (0..<count).map { index in
                decodedWords[index * decodedWords.count / count]
            }
        }
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
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
