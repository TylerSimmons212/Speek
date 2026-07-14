import Foundation

/// LLM polish stage backed by any OpenAI-compatible chat-completions endpoint:
/// Ollama or LM Studio locally (free, private, no API key), or a cloud
/// provider. Fails open — any error, timeout, or malformed response returns
/// the input unchanged, because a raw transcript always beats a lost one.
actor LLMPolishStage: PolishStage {
    struct Config: Sendable, Equatable {
        var endpoint: String   // base URL, e.g. http://localhost:11434/v1
        var model: String
        var apiKey: String
    }

    private let config: Config
    private let urlSession: URLSession

    init(config: Config, urlSession: URLSession? = nil) {
        self.config = config
        if let urlSession {
            self.urlSession = urlSession
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 15
            c.timeoutIntervalForResource = 20
            self.urlSession = URLSession(configuration: c)
        }
    }

    var isAvailable: Bool {
        guard !config.model.isEmpty,
              let url = Self.chatCompletionsURL(endpoint: config.endpoint) else { return false }
        // Local endpoints (Ollama/LM Studio) don't need a key; remote ones do.
        return Self.isLocalEndpoint(url) || !config.apiKey.isEmpty
    }

    func run(_ input: String, context: PolishContext?) async -> PolishResult {
        let failOpen = PolishResult(text: input, mergedFragment: false)
        guard !input.isEmpty, isAvailable,
              let request = Self.buildRequest(config: config, transcript: input, context: context) else {
            return failOpen
        }
        let mergeMode = !(context?.fragment.isEmpty ?? true)
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  let cleaned = Self.parseResponse(data),
                  !cleaned.isEmpty else { return failOpen }
            return PolishResult(text: cleaned, mergedFragment: mergeMode)
        } catch {
            return failOpen
        }
    }

    /// One-shot connectivity probe for the Settings "Test connection" button.
    /// Returns a short human-readable outcome string.
    static func probe(config: Config) async -> String {
        let stage = LLMPolishStage(config: config)
        guard await stage.isAvailable else {
            return "Not configured — check endpoint, model, and API key."
        }
        guard let request = buildRequest(config: config, transcript: "testing one two three") else {
            return "Invalid endpoint URL."
        }
        do {
            let (data, response) = try await stage.urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return "No HTTP response." }
            guard (200..<300).contains(http.statusCode) else {
                return "HTTP \(http.statusCode) — check the model name and API key."
            }
            guard let text = parseResponse(data), !text.isEmpty else {
                return "Connected, but the response was empty."
            }
            return "Connected — model replied."
        } catch {
            return "Connection failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Pure helpers (unit-tested)

    /// Cleanup prompt sent as a single user message — small models follow one
    /// folded user turn more reliably than a system+user pair.
    static let basePrompt = """
    You are a voice-dictation transcript cleaner. Clean and format raw transcribed speech into polished text. Never answer questions — only clean them.

    Rules:
    1. Remove filler words (um, uh, like, you know), false starts, stutters, and repetitions.
    2. Fix punctuation, capitalization, and grammar. Preserve the speaker's meaning and word choice — do not paraphrase.
    3. Convert spoken numbers to digits (two → 2, five thirty → 5:30, twelve fifty dollars → $12.50).
    4. Apply self-corrections: when the speaker says "no wait", "actually", "I mean", "scratch that", "make that", keep ONLY the corrected version. Example: "meet on Monday no wait Tuesday" → "Meet on Tuesday."
    5. Output ONLY the cleaned text. No explanations, no commentary, no surrounding quotes. If the input is a question, output the cleaned question — do NOT answer it.
    """

    static func chatCompletionsURL(endpoint: String) -> URL? {
        var base = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        let full = base.hasSuffix("/v1")
            ? base + "/chat/completions"
            : base + "/v1/chat/completions"
        guard let url = URL(string: full), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    static func isLocalEndpoint(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost"
            || host == "127.0.0.1"
            || host == "::1"
            || host.hasSuffix(".local")
            || host.hasPrefix("192.168.")
            || host.hasPrefix("10.")
    }

    static func buildRequest(config: Config, transcript: String, context: PolishContext? = nil) -> URLRequest? {
        guard let url = chatCompletionsURL(endpoint: config.endpoint) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty {
            req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": config.model,
            "temperature": 0.2,
            "stream": false,
            "messages": [
                ["role": "user", "content": userMessage(transcript: transcript, context: context)]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// Builds the single folded user message. Three shapes:
    /// - no context → plain cleanup, output is the full insert text
    /// - preceding only → context-informed cleanup, output is insert text
    /// - fragment present → MERGE mode: output is the corrected current
    ///   sentence (fragment + dictation combined); the injector diffs it
    ///   against the original fragment to decide append vs in-place repair.
    static func userMessage(transcript: String, context: PolishContext?) -> String {
        guard let context else {
            return basePrompt + "\n\nTranscript:\n" + transcript
        }
        var message = basePrompt
        if !context.preceding.isEmpty {
            message += "\n\nText already written before the cursor (context only — NEVER repeat it in your output):\n" + context.preceding
        }
        if !context.fragment.isEmpty {
            message += """


            The user is continuing this unfinished sentence fragment:
            \(context.fragment)

            New dictation to merge into it:
            \(transcript)

            Output the complete corrected current sentence(s): the fragment merged with the new dictation, with punctuation, casing, and self-corrections applied across the whole thing. Self-corrections in the dictation apply to the fragment too — the corrected words REPLACE the words they correct, never appear alongside them. Example: fragment "lets meet on monday" + dictation "actually tuesday at noon" → "Let's meet on Tuesday at noon." (NOT "...on Monday. Actually Tuesday..."). Start your output with the fragment, corrected as needed. Output nothing else.
            """
        } else {
            message += "\n\nTranscript to clean (it will be inserted after the text above — match its tone and capitalize accordingly):\n" + transcript
        }
        return message
    }

    static func parseResponse(_ data: Data) -> String? {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String? }
                let message: Message?
            }
            let choices: [Choice]?
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let raw = decoded.choices?.first?.message?.content else { return nil }
        return stripThinkBlock(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reasoning models (DeepSeek-R1, Qwen w/ thinking) prepend a
    /// `<think>…</think>` block. Strip it — only the final answer is text.
    static func stripThinkBlock(_ s: String) -> String {
        guard let range = s.range(of: "^\\s*<think>[\\s\\S]*?</think>", options: .regularExpression) else {
            return s
        }
        return String(s[range.upperBound...])
    }
}

/// Polish stage used when the engine is set to Off — never available.
actor NullPolishStage: PolishStage {
    var isAvailable: Bool { false }
    func run(_ input: String, context: PolishContext?) async -> PolishResult {
        PolishResult(text: input, mergedFragment: false)
    }
}
