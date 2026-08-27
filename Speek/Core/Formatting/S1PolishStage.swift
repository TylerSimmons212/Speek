import Foundation
import llama

/// LLM polish stage backed by s1-mini ("S1-mini" by Superwhisper) — a 0.6B
/// Qwen3 fine-tune purpose-built to turn raw ASR output into clean written
/// text: fillers dropped, self-corrections resolved to what the speaker
/// landed on, punctuation and capitalization applied, spoken numbers, dates,
/// and currency rendered in written form. Runs fully on-device through
/// llama.cpp (Metal), using the official Q4_K_M GGUF.
///
/// Fails open — any load or decode error returns the input unchanged. An
/// empty result for non-empty input is valid (filler-only dictation).
///
/// A singleton so the ~500 MB resident model survives pipeline rebuilds
/// (Settings changes recreate the FormattingPipeline, not this actor).
actor S1PolishStage: PolishStage {
    static let shared = S1PolishStage()

    private var model: OpaquePointer?          // llama_model *
    private var context: OpaquePointer?        // llama_context *
    private var sampler: UnsafeMutablePointer<llama_sampler>?
    private var loadFailed = false

    /// s1-mini is trained for ~1k-token passes; 2048 fits system prompt +
    /// a chunked input + the 1.3× output budget with headroom, and keeps the
    /// fp16 KV cache small.
    private let contextTokens: Int32 = 2048

    private init() {}

    var isAvailable: Bool {
        !loadFailed && S1ModelStore.isModelPresent
    }

    /// Loads the model into memory. Called at app launch to hide the one-time
    /// Metal compile + weight load; also invoked lazily by run(). No-op when
    /// already loaded, previously failed, or weights are missing.
    func prepare() {
        guard context == nil, !loadFailed, S1ModelStore.isModelPresent else { return }
        llama_backend_init()
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(S1ModelStore.modelURL.path, modelParams) else {
            NSLog("S1PolishStage: model load failed")
            loadFailed = true
            return
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextTokens)
        contextParams.n_batch = UInt32(contextTokens)
        guard let context = llama_init_from_model(model, contextParams) else {
            NSLog("S1PolishStage: context init failed")
            llama_model_free(model)
            loadFailed = true
            return
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        // Greedy only — the model card is explicit that sampling degrades it.
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        self.model = model
        self.context = context
        self.sampler = sampler
        NSLog("S1PolishStage: s1-mini loaded")
    }

    /// Frees the model (used when the polish engine is switched off in
    /// Settings — no reason to keep half a gigabyte resident). Also clears a
    /// previous load failure so a re-enable retries.
    func unload() {
        if let sampler { llama_sampler_free(sampler) }
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        sampler = nil
        context = nil
        model = nil
        loadFailed = false
    }

    func run(_ input: String) async -> String {
        guard !input.isEmpty else { return input }
        prepare()
        guard context != nil else { return input }
        var pieces: [String] = []
        for chunk in S1Prompt.chunk(input) {
            guard let cleaned = normalize(chunk) else { return input } // fail open
            if !cleaned.isEmpty { pieces.append(cleaned) }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Inference

    private func normalize(_ transcript: String) -> String? {
        guard let model, let context, let sampler else { return nil }
        let vocab = llama_model_get_vocab(model)

        var promptTokens = tokenize(S1Prompt.build(transcript: transcript), vocab: vocab)
        guard !promptTokens.isEmpty else { return nil }
        let inputTokenCount = tokenize(transcript, vocab: vocab).count
        let budget = min(
            S1Prompt.maxNewTokens(inputTokenCount: inputTokenCount),
            Int(contextTokens) - promptTokens.count - 8
        )
        guard budget > 0 else { return nil }

        // Each dictation is independent — start from an empty KV cache.
        llama_memory_clear(llama_get_memory(context), true)
        let promptOK = promptTokens.withUnsafeMutableBufferPointer { buffer in
            llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))) == 0
        }
        guard promptOK else { return nil }

        var bytes: [UInt8] = []
        var token = llama_sampler_sample(sampler, context, -1)
        var generated = 0
        while generated < budget, !llama_vocab_is_eog(vocab, token) {
            appendPiece(token, vocab: vocab, to: &bytes)
            generated += 1
            var stepToken = token
            let stepOK = withUnsafeMutablePointer(to: &stepToken) { pointer in
                llama_decode(context, llama_batch_get_one(pointer, 1)) == 0
            }
            guard stepOK else { return nil }
            token = llama_sampler_sample(sampler, context, -1)
        }
        return String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// parse_special is on so the hand-built ChatML markers tokenize as the
    /// single control tokens the model was trained on.
    private func tokenize(_ text: String, vocab: OpaquePointer?) -> [llama_token] {
        var tokens = [llama_token](repeating: 0, count: text.utf8.count + 16)
        let count = text.withCString { cString in
            tokens.withUnsafeMutableBufferPointer { buffer in
                llama_tokenize(
                    vocab, cString, Int32(strlen(cString)),
                    buffer.baseAddress, Int32(buffer.count),
                    /* add_special */ false, /* parse_special */ true
                )
            }
        }
        guard count > 0 else { return [] }
        tokens.removeLast(tokens.count - Int(count))
        return tokens
    }

    /// Appends a token's raw UTF-8 bytes; decoding happens once at the end so
    /// multi-byte characters split across tokens survive.
    private func appendPiece(_ token: llama_token, vocab: OpaquePointer?, to bytes: inout [UInt8]) {
        var buffer = [CChar](repeating: 0, count: 256)
        let written = buffer.withUnsafeMutableBufferPointer {
            llama_token_to_piece(vocab, token, $0.baseAddress, Int32($0.count), 0, false)
        }
        guard written > 0 else { return }
        bytes.append(contentsOf: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) })
    }
}
