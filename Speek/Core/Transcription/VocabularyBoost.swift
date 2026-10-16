import FluidAudio
import Foundation

/// Maps Speek's custom vocabulary onto FluidAudio CTC boosting terms. Pure, so
/// it's unit-testable without models. The state that uses it lives in
/// `VocabularyBooster`.
///
/// `SettingsStore.customReplacements` maps what Parakeet wrote (the misheard
/// form) to the spelling the user wants. The wanted spelling becomes the
/// canonical term (`text`), and every source mapping to it becomes an alias.
/// The rescorer matches the decoder transcript against both, then replaces a
/// span only when the CTC encoder's acoustic evidence favors the term.
enum VocabularyBoostMapping {
    /// Canonical terms shorter than this stay RuleStage-only. Short keywords
    /// align to nearly any frame run and over-fire on ordinary English;
    /// FluidAudio's CustomVocabulary.md recommends at least 4 characters.
    static let minTermLength = 4
    /// Replacements past these limits are text snippets ("addr" → a street
    /// address), not something a speaker says aloud, so there's no acoustic
    /// evidence to score. They stay RuleStage-only.
    static let maxTermWords = 4
    static let maxTermLength = 40

    /// Boosting terms for `replacements`, sorted by canonical text. Empty when
    /// nothing in the vocabulary is worth an acoustic pass.
    static func terms(from replacements: [String: String]) -> [CustomVocabularyTerm] {
        var aliasesByText: [String: [String]] = [:]
        for (source, target) in replacements {
            let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isBoostable(text) else { continue }
            let alias = source.trimmingCharacters(in: .whitespacesAndNewlines)
            var aliases = aliasesByText[text, default: []]
            // A casing-only entry ("github" → "GitHub") adds no new spelling
            // to match; the canonical form already covers it.
            if !alias.isEmpty, alias.lowercased() != text.lowercased() {
                aliases.append(alias)
            }
            aliasesByText[text] = aliases
        }

        return aliasesByText.keys.sorted().map { text in
            let aliases = deduplicatedCaseInsensitive(aliasesByText[text] ?? [])
            return CustomVocabularyTerm(text: text, aliases: aliases.isEmpty ? nil : aliases)
        }
    }

    /// The boosting context for `replacements`, or nil when boosting should
    /// stay off (and the CTC encoder unloaded).
    static func context(from replacements: [String: String]) -> CustomVocabularyContext? {
        let terms = terms(from: replacements)
        guard !terms.isEmpty else { return nil }
        return CustomVocabularyContext(terms: terms)
    }

    /// Whether `text` is something the CTC spotter can score as a spoken term.
    static func isBoostable(_ text: String) -> Bool {
        guard text.count >= minTermLength, text.count <= maxTermLength else { return false }
        guard text.contains(where: \.isLetter) else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count <= maxTermWords
    }

    /// Sorted, with case-insensitive duplicates collapsed to the first
    /// spelling in sort order, so the output doesn't depend on dictionary order.
    private static func deduplicatedCaseInsensitive(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.sorted().filter { seen.insert($0.lowercased()).inserted }
    }
}

/// A ready boosting setup: FluidAudio's rescoring session plus Speek's text
/// policy for the same vocabulary.
struct VocabularyBoost: Sendable {
    let session: VocabularyBoostingSession
    let policy: VocabularyRescorePolicy
}

/// The CTC side of vocabulary boosting: the parakeet-ctc-110m encoder
/// (~98 MB, downloaded the first time the vocabulary has a boostable term) and
/// the `VocabularyBoost` built from the current vocabulary.
///
/// With no boostable terms there's no session and no CTC model in memory, and
/// transcription runs exactly as it did before boosting existed.
actor VocabularyBooster {
    /// Spotter-anchored rescue off. That pass proposes a term wherever the CTC
    /// spotter "hears" it, regardless of what TDT wrote. On dictation-style
    /// clips it rewrote the last words of 7 of 18 ordinary sentences
    /// ("…before the end of the day" → "…Superwhisper") and found no term the
    /// similarity-gated paths missed. FluidAudio recommends turning it off for
    /// small vocabularies of user terms (CustomVocabulary.md, #724), and it
    /// already never runs past 10 terms. With it off, every candidate is
    /// string-similarity gated, which is what makes the text preflight sound.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    private var boost: VocabularyBoost?
    private var models: CtcModels?
    private var modelsTask: Task<CtcModels, Error>?
    /// What the user's vocabulary currently maps to. Nil means boosting is off.
    private var desired: CustomVocabularyContext?
    /// Bumped on every update so a slow build can't install a stale vocabulary.
    private var generation = 0
    private var buildsInFlight = 0

    /// Whether a boosting session is ready to rescore.
    var isActive: Bool { boost != nil }

    /// Rebuilds boosting for a new vocabulary. Returns once the new session is
    /// installed, or once the build fails (logged). Until then, decodes keep
    /// using the previous session, or none.
    func update(replacements: [String: String]) async {
        generation += 1
        let gen = generation
        guard let context = VocabularyBoostMapping.context(from: replacements) else {
            desired = nil
            boost = nil
            models = nil
            return
        }
        desired = context
        await build(context, generation: gen)
    }

    /// The boost to rescore with, or nil when boosting is off or not ready.
    /// If an earlier build failed (say, offline on first run), this starts a
    /// background retry. The decode in hand never waits on it.
    func active() -> VocabularyBoost? {
        if boost == nil, buildsInFlight == 0, let desired {
            let gen = generation
            Task { await self.build(desired, generation: gen) }
        }
        return boost
    }

    private func build(_ context: CustomVocabularyContext, generation gen: Int) async {
        buildsInFlight += 1
        defer { buildsInFlight -= 1 }
        do {
            let models = try await loadModels()
            let session = try await VocabularyBoostingSession(
                vocabulary: context, ctcModels: models, config: Self.rescorerConfig
            )
            guard gen == generation else { return }
            // Policy from the session's vocabulary: terms the CTC tokenizer
            // couldn't encode were dropped there and can't be rescored.
            boost = VocabularyBoost(session: session, policy: VocabularyRescorePolicy(context: session.vocabulary))
            NSLog("VocabularyBooster: boosting \(session.vocabulary.terms.count) term(s)")
        } catch {
            NSLog("VocabularyBooster: boosting unavailable — \(error)")
        }
    }

    /// Downloads (first time only) and loads the CTC encoder, sharing one
    /// in-flight load between overlapping builds.
    private func loadModels() async throws -> CtcModels {
        if let models { return models }
        let task: Task<CtcModels, Error>
        if let inFlight = modelsTask {
            task = inFlight
        } else {
            task = Task { try await CtcModels.downloadAndLoad() }
            modelsTask = task
        }
        do {
            let loaded = try await task.value
            if modelsTask == task {
                modelsTask = nil
                // The vocabulary may have been emptied mid-load. Don't keep
                // the encoder loaded for nothing.
                if desired != nil { models = loaded }
            }
            return loaded
        } catch {
            if modelsTask == task { modelsTask = nil }
            throw error
        }
    }
}
