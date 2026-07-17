import Foundation

/// A Kokoro neural voice: a ~0.5 MB style-vector pack applied to the shared
/// 82M acoustic model. Every entry here uses the standard Kokoro voice-pack
/// format (verified byte-identical between the CoreML and ONNX exports), so
/// packs download once from Hugging Face and drop into the model cache.
struct KokoroVoice: Identifiable, Equatable {
    /// Pack name as it appears upstream, e.g. "af_bella"
    /// (a=American/b=British + f/m).
    let pack: String
    /// Display name, e.g. "Bella".
    let name: String
    /// Short flavor line for the picker, e.g. "American · Female".
    let flavor: String

    /// The identifier stored in settings ("kokoro:af_bella").
    var id: String { NeuralSpeechEngine.voiceIdentifierPrefix + pack }
}

/// Curated subset of the 29 upstream English voices — the ones with decent
/// official quality grades. (The full set includes several D/F-grade voices
/// that would only make the feature look bad.)
enum KokoroVoiceCatalog {
    static let voices: [KokoroVoice] = [
        // American — female
        KokoroVoice(pack: "af_heart", name: "Heart", flavor: "American · Female"),
        KokoroVoice(pack: "af_bella", name: "Bella", flavor: "American · Female"),
        KokoroVoice(pack: "af_nicole", name: "Nicole", flavor: "American · Female · Soft-spoken"),
        KokoroVoice(pack: "af_aoede", name: "Aoede", flavor: "American · Female"),
        KokoroVoice(pack: "af_kore", name: "Kore", flavor: "American · Female"),
        KokoroVoice(pack: "af_sarah", name: "Sarah", flavor: "American · Female"),
        // American — male
        KokoroVoice(pack: "am_michael", name: "Michael", flavor: "American · Male"),
        KokoroVoice(pack: "am_fenrir", name: "Fenrir", flavor: "American · Male"),
        KokoroVoice(pack: "am_puck", name: "Puck", flavor: "American · Male"),
        // British — female
        KokoroVoice(pack: "bf_emma", name: "Emma", flavor: "British · Female"),
        KokoroVoice(pack: "bf_isabella", name: "Isabella", flavor: "British · Female"),
        // British — male
        KokoroVoice(pack: "bm_george", name: "George", flavor: "British · Male"),
        KokoroVoice(pack: "bm_fable", name: "Fable", flavor: "British · Male"),
    ]

    /// "kokoro:af_bella" → the catalog entry, or nil for unknown/non-neural ids.
    static func voice(forIdentifier identifier: String) -> KokoroVoice? {
        voices.first { $0.id == identifier }
    }

    /// "kokoro:af_bella" → "af_bella". Nil when the id isn't a neural voice.
    /// Unknown-but-well-formed packs pass through (forward compatibility with
    /// ids persisted by future versions).
    static func pack(fromIdentifier identifier: String) -> String? {
        guard identifier.hasPrefix(NeuralSpeechEngine.voiceIdentifierPrefix) else { return nil }
        let pack = String(identifier.dropFirst(NeuralSpeechEngine.voiceIdentifierPrefix.count))
        guard !pack.isEmpty, pack.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return pack
    }
}
