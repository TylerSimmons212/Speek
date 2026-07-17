import Foundation

/// Splits text into sentences for neural TTS: the models cap input length
/// per utterance, so long passages are synthesized sentence-by-sentence (and
/// queued for playback, which also gets the first audio out fast). Each
/// chunk carries its UTF-16 range in the ORIGINAL text so the overlay can
/// highlight the sentence currently being spoken.
enum SentenceChunker {
    struct Chunk: Equatable {
        /// The text handed to the synthesizer (never empty, trimmed of
        /// surrounding whitespace).
        let text: String
        /// UTF-16 range of `text` within the original string.
        let range: NSRange
    }

    /// Conservative per-utterance cap in UTF-16 units — well under the
    /// ~512-token encoder limits of the CoreML TTS backends.
    static let defaultMaxLength = 400

    static func split(_ text: String, maxLength: Int = defaultMaxLength) -> [Chunk] {
        let ns = text as NSString
        var chunks: [Chunk] = []
        let terminators = CharacterSet(charactersIn: ".!?…\n")

        var sentenceStart = 0
        var i = 0
        while i < ns.length {
            let isTerminator = Unicode.Scalar(ns.character(at: i)).map(terminators.contains) ?? false
            if isTerminator {
                // Absorb a run of terminators/closing quotes (e.g. `?!`, `."`).
                var end = i + 1
                let absorbable = CharacterSet(charactersIn: ".!?…\"'”’)]")
                while end < ns.length,
                      let scalar = Unicode.Scalar(ns.character(at: end)),
                      absorbable.contains(scalar) {
                    end += 1
                }
                appendChunks(from: ns, start: sentenceStart, end: end, maxLength: maxLength, into: &chunks)
                sentenceStart = end
                i = end
            } else {
                i += 1
            }
        }
        appendChunks(from: ns, start: sentenceStart, end: ns.length, maxLength: maxLength, into: &chunks)
        return chunks
    }

    /// Emits one chunk for [start, end), sub-splitting anything longer than
    /// maxLength at the last space (or hard boundary as a last resort).
    private static func appendChunks(
        from ns: NSString, start: Int, end: Int, maxLength: Int, into chunks: inout [Chunk]
    ) {
        var cursor = start
        while cursor < end {
            var sliceEnd = min(end, cursor + maxLength)
            if sliceEnd < end {
                // Prefer breaking at whitespace so the synthesizer never gets
                // half a word.
                var probe = sliceEnd
                while probe > cursor,
                      let scalar = Unicode.Scalar(ns.character(at: probe - 1)),
                      !CharacterSet.whitespacesAndNewlines.contains(scalar) {
                    probe -= 1
                }
                if probe > cursor { sliceEnd = probe }
            }
            if let chunk = trimmedChunk(from: ns, start: cursor, end: sliceEnd) {
                chunks.append(chunk)
            }
            cursor = sliceEnd
        }
    }

    /// Trims surrounding whitespace but keeps the range anchored to the
    /// original string. Returns nil for whitespace-only spans.
    private static func trimmedChunk(from ns: NSString, start: Int, end: Int) -> Chunk? {
        var s = start
        var e = end
        while s < e,
              let scalar = Unicode.Scalar(ns.character(at: s)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            s += 1
        }
        while e > s,
              let scalar = Unicode.Scalar(ns.character(at: e - 1)),
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            e -= 1
        }
        guard s < e else { return nil }
        let range = NSRange(location: s, length: e - s)
        return Chunk(text: ns.substring(with: range), range: range)
    }
}
