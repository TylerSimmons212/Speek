import Foundation

/// Prompt construction and chunking for s1-mini ("S1-mini" by Superwhisper),
/// a Qwen3-0.6B fine-tune purpose-built to normalize raw ASR transcripts.
/// Pure functions — unit-testable without the model.
///
/// s1-mini's contract (from the model card):
/// - Input: a control line `[Styling: …] [Structure: …] [Context: …]`, a
///   newline, then the raw transcript.
/// - Chat format: Qwen3 ChatML with thinking DISABLED — the assistant turn
///   must be pre-seeded with an empty `<think>` block, or the model returns
///   blank output.
/// - Decoding: greedy only. The model is a deterministic normalizer;
///   sampling adds unwanted variance.
enum S1Prompt {
    /// Exact system prompt from the s1-mini model card.
    static let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    /// Every combination of the three axes was trained, so any PolishStyle
    /// renders to a valid control line.
    static func controlLine(_ style: PolishStyle) -> String {
        "[Styling: \(style.styling.rawValue)] [Structure: \(style.structure.rawValue)] [Context: \(style.context.rawValue)]"
    }

    static func build(transcript: String, style: PolishStyle = .standard) -> String {
        """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(controlLine(style))
        \(transcript)<|im_end|>
        <|im_start|>assistant
        <think>

        </think>


        """
    }

    /// Chunks are normalized independently and joined with a space, so a
    /// whole-document layout (an email's greeting and sign-off, bullet
    /// lines) would repeat or run together across chunks. Multi-chunk
    /// dictations keep their register but fall back to plain prose.
    static func style(_ style: PolishStyle, forChunkCount count: Int) -> PolishStyle {
        count > 1 ? PolishStyle(styling: style.styling) : style
    }

    /// Output budget from the model card: 1.3 × input tokens + 32.
    static func maxNewTokens(inputTokenCount: Int) -> Int {
        Int((Double(inputTokenCount) * 1.3).rounded(.up)) + 32
    }

    /// The model is trained for passes of roughly 1,000 tokens. Longer
    /// dictations are split into chunks it normalizes independently.
    /// ~4 chars/token is a safe planning ratio for English, so this cap keeps
    /// a chunk near 700 tokens — comfortable headroom for prompt + output
    /// inside a 2048-token context.
    static let maxChunkCharacters = 2_800

    /// Splits an over-long transcript at sentence boundaries where they
    /// exist, falling back to word boundaries — raw ASR output often has no
    /// punctuation at all.
    static func chunk(_ transcript: String) -> [String] {
        guard transcript.count > maxChunkCharacters else { return [transcript] }
        var chunks: [String] = []
        var rest = Substring(transcript)
        while rest.count > maxChunkCharacters {
            let window = rest.prefix(maxChunkCharacters)
            let cut = breakIndex(in: window)
            let piece = String(rest[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { chunks.append(piece) }
            rest = rest[cut...]
        }
        let tail = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        return chunks
    }

    private static func breakIndex(in window: Substring) -> Substring.Index {
        for boundary in [". ", "! ", "? ", "\n"] {
            if let r = window.range(of: boundary, options: .backwards) {
                return r.upperBound
            }
        }
        if let r = window.range(of: " ", options: .backwards) {
            return r.upperBound
        }
        return window.endIndex
    }
}
