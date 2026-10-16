import AVFoundation
import Darwin
import FluidAudio
import XCTest
@testable import Speek

/// End-to-end vocabulary boosting against the real Parakeet TDT v2 and
/// parakeet-ctc-110m models, on speech synthesized with `say`. Skipped when
/// either model isn't cached locally; run with
/// `TEST_RUNNER_SPEEK_DOWNLOAD_MODELS=1` to fetch them (~600 MB + ~98 MB).
final class VocabularyBoostIntegrationTests: XCTestCase {
    /// ~10 s of dictation naming terms Parakeet spells its own way.
    static let termSentence =
        "I pushed the new build of Speek to TestFlight this morning, and Tyler wants the "
        + "Wispr Flow comparison and the Superwhisper notes on his desk by Friday afternoon."
    static let ordinarySentence =
        "Can you send me the quarterly numbers before lunch tomorrow? I want to go over "
        + "them with the team and make sure the forecast still holds."

    /// The user's vocabulary. Sources are deliberately not what Parakeet
    /// writes, so RuleStage's exact-match pass alone can't produce the terms.
    static let vocabulary = [
        "wisper flo": "Wispr Flow",
        "super wisper": "Superwhisper",
    ]

    private func requireModels() throws {
        if ProcessInfo.processInfo.environment["SPEEK_DOWNLOAD_MODELS"] == "1" { return }
        try XCTSkipUnless(
            AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2),
            "Parakeet TDT v2 not cached — run the app once to download it"
        )
        try XCTSkipUnless(
            CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory()),
            "parakeet-ctc-110m not cached — add a custom vocabulary term in the app to download it"
        )
    }

    func test_custom_term_is_recognized_via_rescoring() async throws {
        try requireModels()
        let engine = try await EngineCache.shared.engine()
        let clip = try Self.synthesize(Self.termSentence)

        await engine.vocabulary.update(replacements: [:])
        let plain = try await engine.transcribe(samples: clip)

        await engine.vocabulary.update(replacements: Self.vocabulary)
        let boostingActive = await engine.vocabulary.isActive
        XCTAssertTrue(boostingActive)
        let boosted = try await engine.transcribe(samples: clip)
        print("[vocab-boost] plain:   \(plain)")
        print("[vocab-boost] boosted: \(boosted)")

        XCTAssertFalse(plain.contains("Wispr Flow"), "precondition: TDT alone misses the term — got: \(plain)")
        XCTAssertTrue(boosted.contains("the Wispr Flow comparison"), "got: \(boosted)")
        XCTAssertTrue(boosted.contains("the Superwhisper notes"), "got: \(boosted)")
        // Neighboring words and punctuation survive the replacement.
        XCTAssertTrue(boosted.hasSuffix("by Friday afternoon."), "got: \(boosted)")
        // RuleStage's needles ("wisper flo") never occur in the TDT output,
        // so the terms above came from acoustic rescoring.
        let ruleOnly = RuleStage(customReplacements: Self.vocabulary).run(plain)
        XCTAssertFalse(ruleOnly.contains("Wispr Flow"), "got: \(ruleOnly)")

        // Preview decodes skip the CTC pass.
        let preview = try await engine.transcribePreview(samples: clip)
        XCTAssertEqual(preview, plain)
        await engine.vocabulary.update(replacements: [:])
    }

    func test_ordinary_speech_is_left_alone() async throws {
        try requireModels()
        let engine = try await EngineCache.shared.engine()
        let clip = try Self.synthesize(Self.ordinarySentence)

        await engine.vocabulary.update(replacements: [:])
        let plain = try await engine.transcribe(samples: clip)
        await engine.vocabulary.update(replacements: Self.vocabulary)
        let boosted = try await engine.transcribe(samples: clip)
        await engine.vocabulary.update(replacements: [:])

        XCTAssertEqual(boosted, plain)
    }

    /// Reports decode latency for a 10 s clip with and without boosting, and
    /// the process memory the CTC encoder adds, under `[vocab-boost]` in the
    /// test log. This is a Debug build inside the app host (FluidAudio's Swift
    /// DP runs unoptimized and the host app is starting up alongside), so
    /// treat the numbers as a smoke check. The PR has Release numbers.
    func test_measure_boosting_overhead() async throws {
        try requireModels()
        let engine = try await EngineCache.shared.engine()
        let clip = try Self.synthesize(Self.termSentence)
        let ordinary = try Self.synthesize(Self.ordinarySentence)
        XCTAssertEqual(clip.count, 160_000)
        let iterations = 5

        await engine.vocabulary.update(replacements: [:])
        for _ in 0..<2 { _ = try await engine.transcribe(samples: clip) }
        let memBefore = Self.memory()
        let plainMs = try await Self.median(iterations) { _ = try await engine.transcribe(samples: clip) }
        let plainOrdinaryMs = try await Self.median(iterations) { _ = try await engine.transcribe(samples: ordinary) }

        let loadStart = ContinuousClock.now
        await engine.vocabulary.update(replacements: Self.vocabulary)
        let loadMs = Self.ms(ContinuousClock.now - loadStart)
        let memLoaded = Self.memory()
        _ = try await engine.transcribe(samples: clip)
        let boostedMs = try await Self.median(iterations) { _ = try await engine.transcribe(samples: clip) }
        let skippedMs = try await Self.median(iterations) { _ = try await engine.transcribe(samples: ordinary) }
        let memBoosted = Self.memory()

        await engine.vocabulary.update(replacements: [:])
        _ = try await engine.transcribe(samples: clip)
        let memUnloaded = Self.memory()

        func f(_ x: Double) -> String { String(format: "%.0f ms", x) }
        func mb(_ bytes: UInt64) -> String { String(format: "%.0f MB", Double(bytes) / 1_048_576) }
        print("[vocab-boost] 10 s clip, median of \(iterations), Debug:")
        print("[vocab-boost]   term clip      TDT \(f(plainMs)) → boosted \(f(boostedMs))")
        print("[vocab-boost]   ordinary clip  TDT \(f(plainOrdinaryMs)) → preflight skip \(f(skippedMs))")
        print("[vocab-boost]   session build  \(f(loadMs))")
        print("[vocab-boost]   resident/footprint: off \(mb(memBefore.resident))/\(mb(memBefore.footprint)), "
            + "loaded \(mb(memLoaded.resident))/\(mb(memLoaded.footprint)), "
            + "after decodes \(mb(memBoosted.resident))/\(mb(memBoosted.footprint)), "
            + "emptied \(mb(memUnloaded.resident))/\(mb(memUnloaded.footprint))")

        // The ordinary clip has nothing near a term: no CTC pass at all.
        XCTAssertLessThan(skippedMs - plainOrdinaryMs, 100, "preflight should skip the CTC pass")
        XCTAssertLessThan(boostedMs - plainMs, 1_500, "boosting overhead regressed badly")
    }

    // MARK: - Helpers

    /// Speech for `text`, as 16 kHz mono Float32, padded or trimmed to 10 s.
    static func synthesize(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("speek-vocab-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-v", "Samantha", "-o", url.path,
            "--file-format=WAVE", "--data-format=LEF32@16000", text,
        ]
        try say.run()
        say.waitUntilExit()
        guard say.terminationStatus == 0 else {
            throw XCTSkip("`say` failed (status \(say.terminationStatus))")
        }

        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        var samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let tenSeconds = 160_000
        if samples.count < tenSeconds {
            samples += [Float](repeating: 0, count: tenSeconds - samples.count)
        } else {
            samples = Array(samples.prefix(tenSeconds))
        }
        return samples
    }

    static func median(_ n: Int, _ body: () async throws -> Void) async throws -> Double {
        var times: [Double] = []
        for _ in 0..<n {
            let start = ContinuousClock.now
            try await body()
            times.append(ms(ContinuousClock.now - start))
        }
        return times.sorted()[n / 2]
    }

    static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1_000 + Double(d.components.attoseconds) / 1e15
    }

    static func memory() -> (resident: UInt64, footprint: UInt64) {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return (0, 0) }
        return (info.ri_resident_size, info.ri_phys_footprint)
    }
}

/// One Parakeet load for the whole class. Loading compiles CoreML models for
/// the ANE, which takes seconds.
private actor EngineCache {
    static let shared = EngineCache()
    private var engine: ParakeetEngine?

    func engine() async throws -> ParakeetEngine {
        if let engine { return engine }
        let loaded = try await ParakeetEngine()
        engine = loaded
        return loaded
    }
}
