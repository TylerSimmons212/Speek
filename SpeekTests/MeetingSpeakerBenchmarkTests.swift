import Accelerate
import AVFoundation
import Darwin
import XCTest
@testable import Speek

/// Opt-in measurements for meeting speaker accuracy, stop latency and echo
/// cancellation. Skipped unless SPEEK_BENCH_DIR points at a fixture:
///
///     scripts/make-meeting-fixture.py /tmp/speek-fixture
///     TEST_RUNNER_SPEEK_BENCH_DIR=/tmp/speek-fixture xcodebuild test … \
///       -only-testing:SpeekTests/MeetingSpeakerBenchmarkTests
///
/// The fixture holds far.wav/.rttm (remote speakers, what the system tap
/// hears) and near.wav/.rttm (the local user). The first run downloads the
/// FluidAudio diarization and LocalVQE models. Results print to the log and
/// land in SPEEK_BENCH_DIR as JSON.
final class MeetingSpeakerBenchmarkTests: XCTestCase {
    typealias R = OfflineSpeakerRelabeler
    private static let rate = 16_000
    private static let tick = 8_000 // the meeting pump's 500 ms drain

    private var dir: URL!

    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["SPEEK_BENCH_DIR"] else {
            throw XCTSkip("Set SPEEK_BENCH_DIR (see scripts/make-meeting-fixture.py) to run meeting benchmarks.")
        }
        dir = URL(fileURLWithPath: path)
    }

    // MARK: - Live vs offline labels

    /// The same pause-bounded windows labeled two ways: the shipped live
    /// path (online DiarizerManager per window) and the offline full-track
    /// pass + overlap relabel.
    func test_live_vs_offline_speaker_labels() async throws {
        let far = try Self.loadWav(dir.appendingPathComponent("far.wav"))
        let near = try Self.loadWav(dir.appendingPathComponent("near.wav"))
        let truth = try Self.parseRTTM(dir.appendingPathComponent("far.rttm"))

        let windows = Self.simulateWindows(system: far, mic: near)
        let them = windows.filter { $0.verdict.them && $0.system.count >= Self.rate }

        let diarizer = MeetingDiarizer()
        await diarizer.startSession()
        var labeler = SpeakerLabeler()
        var live: [String?] = []
        let liveStart = Date()
        for window in them {
            let id = await diarizer.dominantSpeakerId(in: window.system)
            live.append(id.map { labeler.label(forId: $0) })
        }
        let liveSeconds = Date().timeIntervalSince(liveStart)

        let items = zip(them, live).map { window, label in R.Item(span: window.systemSpan, provisionalLabel: label) }
        let spool = try XCTUnwrap(SystemTrackSpool())
        for start in stride(from: 0, to: far.count, by: Self.tick) {
            spool.append(Array(far[start..<min(start + Self.tick, far.count)]))
        }
        let source = try XCTUnwrap(spool.finish())
        let loaded = await diarizer.takeOfflineModels()
        let models = try XCTUnwrap(loaded, "offline models didn't load")
        let offlineStart = Date()
        let turns = try await MeetingDiarizer.diarizeFullTrack(source, models: models)
        let offline = try XCTUnwrap(R.relabel(items: items, turns: turns))
        let offlineSeconds = Date().timeIntervalSince(offlineStart)
        await diarizer.endSession()

        let duration = Double(far.count) / Double(Self.rate)
        let liveScore = Self.score(items: items, labels: live, truth: truth, duration: duration)
        let offlineScore = Self.score(items: items, labels: offline, truth: truth, duration: duration)
        let rawDER = Self.frameDER(hypothesis: turns, truth: truth, duration: duration)

        let report: [String: Any] = [
            "audioMinutes": duration / 60,
            "truthSpeakers": Set(truth.map(\.speakerId)).count,
            "remoteSegments": items.count,
            "live": liveScore.json + ["seconds": liveSeconds],
            "offlineRelabel": offlineScore.json + ["seconds": offlineSeconds],
            "offlineDiarizerFrameDER": rawDER.json,
            "offlineSpeakers": Set(turns.map(\.speakerId)).count,
        ]
        try Self.write(report, named: "labels", in: dir)
        XCTAssertLessThanOrEqual(offlineScore.segmentError, liveScore.segmentError + 0.02)
    }

    // MARK: - Stop latency on a long recording

    /// The offline pass for an hour-long call: spool finish + diarization +
    /// relabel (stop→relabeled file, minus the final flush). Also reports
    /// the per-tick spool write cost paid during the call, memory, and how
    /// the offline labels hold up over an hour.
    func test_offline_relabel_cost_on_an_hour_long_track() async throws {
        let minutes = Double(ProcessInfo.processInfo.environment["SPEEK_BENCH_MINUTES"] ?? "60") ?? 60
        let far = try Self.loadWav(dir.appendingPathComponent("far.wav"))
        let near = try Self.loadWav(dir.appendingPathComponent("near.wav"))
        let truth = try Self.parseRTTM(dir.appendingPathComponent("far.rttm"))
        let unit = Double(far.count) / Double(Self.rate)
        let copies = Int((minutes * 60 / unit).rounded(.up))
        var system: [Float] = []
        var tiledTruth: [R.Turn] = []
        system.reserveCapacity(far.count * copies)
        for copy in 0..<copies {
            system += far
            let shift = Double(copy) * unit
            tiledTruth += truth.map { R.Turn(speakerId: $0.speakerId, start: $0.start + shift, end: $0.end + shift) }
        }
        let duration = Double(system.count) / Double(Self.rate)

        let diarizer = MeetingDiarizer()
        await diarizer.startSession() // the app preloads at meeting start

        let spool = try XCTUnwrap(SystemTrackSpool())
        var appendSeconds: TimeInterval = 0
        var ticks = 0
        for start in stride(from: 0, to: system.count, by: Self.tick) {
            let chunk = Array(system[start..<min(start + Self.tick, system.count)])
            let t0 = Date()
            spool.append(chunk)
            appendSeconds += Date().timeIntervalSince(t0)
            ticks += 1
        }
        system = [] // the app never holds the whole track in RAM

        let loaded = await diarizer.takeOfflineModels()
        let models = try XCTUnwrap(loaded, "offline models didn't load")
        let footprintBefore = Self.physFootprintMB()
        let sampler = Task.detached {
            var peak = 0.0
            while !Task.isCancelled {
                peak = max(peak, Self.physFootprintMB())
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return peak
        }
        let stopStart = Date()
        let source = try XCTUnwrap(spool.finish())
        let finished = Date()
        let turns = try await MeetingDiarizer.diarizeFullTrack(source, models: models)
        let diarized = Date()
        sampler.cancel()
        let footprintPeak = await sampler.value
        let windows = Self.simulateWindows(systemSource: source, tiledMic: near)
        let items = windows.filter { $0.verdict.them && $0.systemCount >= Self.rate }
            .map { R.Item(span: $0.systemSpan, provisionalLabel: nil) }
        let relabelStart = Date()
        let labels = try XCTUnwrap(R.relabel(items: items, turns: turns))
        let relabelEnd = Date()
        let footprintAfter = Self.physFootprintMB()
        await diarizer.endSession()

        let score = Self.score(items: items, labels: labels, truth: tiledTruth, duration: duration)
        let report: [String: Any] = [
            "audioMinutes": duration / 60,
            "spoolMB": Double(spool.sampleCount * 2) / 1_048_576,
            "spoolAppendMsPerTick": appendSeconds / Double(ticks) * 1000,
            "finishSeconds": finished.timeIntervalSince(stopStart),
            "offlineDiarizeSeconds": diarized.timeIntervalSince(finished),
            "relabelSeconds": relabelEnd.timeIntervalSince(relabelStart),
            "relabeledFileAfterSeconds": finished.timeIntervalSince(stopStart) + diarized.timeIntervalSince(finished)
                + relabelEnd.timeIntervalSince(relabelStart),
            "realtimeFactor": duration / diarized.timeIntervalSince(finished),
            "physFootprintMB": ["beforeStop": footprintBefore, "peakDuringOffline": footprintPeak, "afterRelabel": footprintAfter],
            "remoteSegments": items.count,
            "offlineSpeakers": Set(turns.map(\.speakerId)).count,
            "offlineRelabel": score.json,
        ]
        try Self.write(report, named: "hour", in: dir)
    }

    // MARK: - Echo cancellation

    /// A laptop-speaker call: the mic hears the user plus the remote side
    /// through a synthetic room. Counts "You" windows with no local speech
    /// (the duplicates users see) with and without LocalVQE, at three
    /// speaker volumes.
    func test_echo_cancellation_on_a_laptop_speaker_call() async throws {
        let far = try Self.loadWav(dir.appendingPathComponent("far.wav"))
        let near = try Self.loadWav(dir.appendingPathComponent("near.wav"))
        let nearTruth = try Self.parseRTTM(dir.appendingPathComponent("near.rttm"))
        let farTruth = try Self.parseRTTM(dir.appendingPathComponent("far.rttm"))
        let room = Self.roomImpulseResponse()
        let reverberant = Self.convolve(far, room)
        let farRMS = Self.rms(far)
        let reverbRMS = Self.rms(Array(reverberant.prefix(far.count)))

        var results: [[String: Any]] = []
        for echoLevel in [0.25, 0.5, 1.0] as [Float] {
            // echoLevel = echo RMS at the mic relative to the tap's RMS.
            let gain = echoLevel * farRMS / reverbRMS
            var mic = [Float](repeating: 0, count: far.count)
            var noise = Lcg(seed: 11)
            for i in mic.indices {
                mic[i] = near[i] + gain * reverberant[i] + 0.0005 * noise.nextGaussian()
            }

            let raw = Self.simulateCall(system: far, mic: mic)
            let start = Date()
            let canceller = MeetingEchoCanceller()
            await canceller.start()
            let isActive = await canceller.isActive
            XCTAssertTrue(isActive, "LocalVQE failed to load")
            let enhanced = try await Self.simulateCall(system: far, mic: mic, canceller: canceller)
            let vqeSeconds = Date().timeIntervalSince(start)

            let rawCounts = Self.countYou(raw.windows, nearTruth: nearTruth)
            let vqeCounts = Self.countYou(enhanced.windows, nearTruth: nearTruth)
            let farOnly = Self.regions(where: farTruth, without: nearTruth, length: far.count)
            let nearOnly = Self.regions(where: nearTruth, without: farTruth, length: far.count)
            results.append([
                "echoLevel": echoLevel,
                "raw": rawCounts.json,
                "vqe": vqeCounts.json + ["seconds": vqeSeconds],
                "echoReductionDB": Self.energyRatioDB(mic, enhanced.micSignal, over: farOnly),
                "nearEndChangeDB": -Self.energyRatioDB(mic, enhanced.micSignal, over: nearOnly),
            ])
        }
        try Self.write(["audioMinutes": Double(far.count) / Double(Self.rate) / 60, "conditions": results], named: "vqe", in: dir)
    }

    // MARK: - Pipeline simulation (mirrors MeetingTranscriptionService)

    struct Window {
        var systemStart: Int
        var systemCount: Int
        var system: [Float]
        var micStart: Int
        var micCount: Int
        var verdict: SpeakerAttributor.Verdict

        var systemSpan: R.Span {
            R.Span(start: Double(systemStart) / 16_000, end: Double(systemStart + systemCount) / 16_000)
        }
    }

    /// Ingest/flush exactly like the service: 500 ms ticks, RMS activity per
    /// track, SilenceGateChunker on the louder track, attribution at flush.
    static func simulateWindows(system: [Float], mic: [Float]) -> [Window] {
        var ticks: [(system: [Float], mic: [Float])] = []
        for start in stride(from: 0, to: system.count, by: tick) {
            let end = min(start + tick, system.count)
            ticks.append((Array(system[start..<end]), Array(mic[min(start, mic.count)..<min(end, mic.count)])))
        }
        return simulate(ticks: ticks, keepSystemAudio: true)
    }

    /// Reads the system track back from the spool; the mic repeats `tiledMic`.
    static func simulateWindows(systemSource: MappedPCM16Source, tiledMic: [Float]) -> [Window] {
        var ticks: [(system: [Float], mic: [Float])] = []
        for start in stride(from: 0, to: systemSource.sampleCount, by: tick) {
            let count = min(tick, systemSource.sampleCount - start)
            var chunk = [Float](repeating: 0, count: count)
            chunk.withUnsafeMutableBufferPointer { try? systemSource.copySamples(into: $0.baseAddress!, offset: start, count: count) }
            let mic = (0..<count).map { tiledMic[(start + $0) % tiledMic.count] }
            ticks.append((chunk, mic))
        }
        return simulate(ticks: ticks, keepSystemAudio: false)
    }

    static func simulate(ticks: [(system: [Float], mic: [Float])], keepSystemAudio: Bool) -> [Window] {
        var windows: [Window] = []
        var gate = SilenceGateChunker()
        var systemActivity = SpeakerAttributor.TrackActivity()
        var micActivity = SpeakerAttributor.TrackActivity()
        var systemWindow: [Float] = []
        var systemCount = 0
        var micCount = 0
        var systemPos = 0
        var micPos = 0
        var systemStart = 0
        var micStart = 0

        func flush() {
            let verdict = SpeakerAttributor.attribute(mic: micActivity, system: systemActivity)
            windows.append(Window(
                systemStart: systemStart, systemCount: systemCount, system: systemWindow,
                micStart: micStart, micCount: micCount, verdict: verdict
            ))
            systemWindow = []
            systemCount = 0
            micCount = 0
            systemActivity = .init()
            micActivity = .init()
            gate.reset()
        }

        for (system, mic) in ticks {
            guard !system.isEmpty || !mic.isEmpty else { continue }
            if systemCount == 0 { systemStart = systemPos }
            if micCount == 0 { micStart = micPos }
            if keepSystemAudio { systemWindow += system }
            systemCount += system.count
            micCount += mic.count
            systemPos += system.count
            micPos += mic.count
            let systemRMS = rms(system)
            let micRMS = rms(mic)
            systemActivity.observe(rms: systemRMS, duration: Double(system.count) / 16_000, threshold: 0.012)
            micActivity.observe(rms: micRMS, duration: Double(mic.count) / 16_000, threshold: 0.012)
            gate.observe(rms: max(systemRMS, micRMS), duration: Double(max(system.count, mic.count)) / 16_000)
            if gate.shouldFlush(windowDuration: Double(systemCount) / 16_000) {
                flush()
            }
        }
        if systemCount > 0 || micCount > 0 { flush() }
        return windows
    }

    struct CallRun {
        var windows: [Window]
        /// The mic track the attributor saw, re-aligned to the far timeline.
        var micSignal: [Float]
    }

    /// The mic engine comes up 300 ms after the tap and delivers 21 ms
    /// buffers, so each drain holds whatever whole buffers have landed.
    static let micStartDelay = 4_800
    static let micBuffer = 336

    static func simulateCall(system: [Float], mic: [Float]) -> CallRun {
        let windows = simulateWindows(system: system, mic: mic)
        return CallRun(windows: windows, micSignal: mic)
    }

    static func simulateCall(system: [Float], mic: [Float], canceller: MeetingEchoCanceller) async throws -> CallRun {
        var ticks: [(system: [Float], mic: [Float])] = []
        var delivered = 0 // mic samples handed over so far (mic-capture timeline)
        var enhancedTotal: [Float] = []
        for start in stride(from: 0, to: system.count, by: tick) {
            let end = min(start + tick, system.count)
            let captured = max(0, end - micStartDelay)
            let available = (captured / micBuffer) * micBuffer
            let micChunk = Array(mic[min(micStartDelay + delivered, mic.count)..<min(micStartDelay + available, mic.count)])
            delivered = max(delivered, available)
            let reference = Array(system[start..<end])
            let enhanced = await canceller.process(mic: micChunk, reference: reference)
            enhancedTotal += enhanced
            ticks.append((reference, enhanced))
        }
        let tail = await canceller.finish()
        enhancedTotal += tail
        if !tail.isEmpty { ticks.append(([], tail)) }
        // Enhanced sample j is captured mic sample j = mic[j + micStartDelay].
        var aligned = [Float](repeating: 0, count: mic.count)
        for (j, value) in enhancedTotal.enumerated() where j + micStartDelay < aligned.count {
            aligned[j + micStartDelay] = value
        }
        var windows = simulate(ticks: ticks, keepSystemAudio: false)
        for i in windows.indices { windows[i].micStart += micStartDelay }
        return CallRun(windows: windows, micSignal: aligned)
    }

    struct YouCounts {
        var youSegments = 0
        var duplicates = 0
        var localTurnsCaught = 0
        var localTurns = 0
        /// "start+duration" of local turns no "You" segment covered.
        var missed: [String] = []
        var json: [String: Any] {
            ["youSegments": youSegments, "duplicateYouSegments": duplicates,
             "localTurnsCaught": "\(localTurnsCaught)/\(localTurns)", "missedLocalTurns": missed]
        }
    }

    /// A "You" segment needs verdict.you and ≥1 s of mic audio (as in the
    /// service); it's a duplicate when the user spoke <0.3 s inside it.
    static func countYou(_ windows: [Window], nearTruth: [R.Turn]) -> YouCounts {
        var counts = YouCounts(localTurns: nearTruth.count)
        var caught = Set<Int>()
        for window in windows where window.verdict.you && window.micCount >= 16_000 {
            counts.youSegments += 1
            let span = R.Span(start: Double(window.micStart) / 16_000, end: Double(window.micStart + window.micCount) / 16_000)
            var local: TimeInterval = 0
            for (index, turn) in nearTruth.enumerated() {
                let overlap = min(span.end, turn.end) - max(span.start, turn.start)
                if overlap > 0 {
                    local += overlap
                    if overlap >= 0.3 { caught.insert(index) }
                }
            }
            if local < 0.3 { counts.duplicates += 1 }
        }
        counts.localTurnsCaught = caught.count
        counts.missed = nearTruth.indices.filter { !caught.contains($0) }.map {
            String(format: "%.1fs+%.1fs", nearTruth[$0].start, nearTruth[$0].end - nearTruth[$0].start)
        }
        return counts
    }

    // MARK: - Scoring

    struct LabelScore {
        /// Duration-weighted share of remote segments whose label maps to the
        /// wrong speaker (or has none) under the best one-to-one mapping.
        var segmentError: Double
        var unlabeled: Double
        /// Frame-level DER of the transcript as written: every segment's
        /// whole span carries its label. Miss/false alarm come from window
        /// boundaries (identical for both labelings); confusion is the label.
        var transcriptDER: DER
        var labels: Int

        var json: [String: Any] {
            ["segmentSpeakerError": segmentError, "unlabeledShare": unlabeled,
             "transcriptDER": transcriptDER.json, "distinctLabels": labels]
        }
    }

    static func score(items: [R.Item], labels: [String?], truth: [R.Turn], duration: TimeInterval) -> LabelScore {
        let truthIds = Array(Set(truth.map(\.speakerId))).sorted()
        let hypIds = Array(Set(labels.compactMap { $0 })).sorted()
        var weights = [[Double]](repeating: [Double](repeating: 0, count: truthIds.count), count: hypIds.count)
        var total = 0.0
        var unlabeled = 0.0
        var pairs: [(hyp: Int?, truth: Int, weight: Double)] = []
        for (item, label) in zip(items, labels) {
            guard let speaker = R.dominantSpeaker(for: item.span, in: truth),
                  let t = truthIds.firstIndex(of: speaker) else { continue }
            let weight = item.span.end - item.span.start
            total += weight
            let h = label.flatMap { hypIds.firstIndex(of: $0) }
            if let h { weights[h][t] += weight } else { unlabeled += weight }
            pairs.append((h, t, weight))
        }
        let mapping = optimalMapping(weights)
        let correct = pairs.reduce(0.0) { sum, pair in
            guard let h = pair.hyp, mapping[h] == pair.truth else { return sum }
            return sum + pair.weight
        }
        let spans = zip(items, labels).compactMap { item, label in
            label.map { R.Turn(speakerId: $0, start: item.span.start, end: item.span.end) }
        }
        // Unlabeled ("Them") spans are speech attributed to nobody.
        let anonymous = zip(items, labels).compactMap { item, label in
            label == nil ? R.Turn(speakerId: "\u{0}them", start: item.span.start, end: item.span.end) : nil
        }
        return LabelScore(
            segmentError: total > 0 ? 1 - correct / total : 0,
            unlabeled: total > 0 ? unlabeled / total : 0,
            transcriptDER: frameDER(hypothesis: spans + anonymous, truth: truth, duration: duration, unmappable: ["\u{0}them"]),
            labels: hypIds.count
        )
    }

    struct DER {
        var miss = 0.0, falseAlarm = 0.0, confusion = 0.0
        var total: Double { miss + falseAlarm + confusion }
        var json: [String: Any] {
            ["der": total, "miss": miss, "falseAlarm": falseAlarm, "confusion": confusion]
        }
    }

    /// Frame-level (10 ms, no collar) diarization error rate: missed +
    /// false-alarm + confused speaker time over reference speech time, with
    /// the best one-to-one hypothesis→reference speaker mapping.
    static func frameDER(hypothesis: [R.Turn], truth: [R.Turn], duration: TimeInterval, unmappable: Set<String> = []) -> DER {
        let frames = Int(duration * 100) + 1
        func grid(_ turns: [R.Turn], ids: [String]) -> [[Int]] {
            var g = [[Int]](repeating: [], count: frames)
            for turn in turns {
                guard let id = ids.firstIndex(of: turn.speakerId) else { continue }
                let a = max(0, Int((turn.start * 100).rounded()))
                let b = min(frames, Int((turn.end * 100).rounded()))
                if a < b { for f in a..<b where !g[f].contains(id) { g[f].append(id) } }
            }
            return g
        }
        let refIds = Array(Set(truth.map(\.speakerId))).sorted()
        let hypIds = Array(Set(hypothesis.map(\.speakerId))).sorted()
        let ref = grid(truth, ids: refIds)
        let hyp = grid(hypothesis, ids: hypIds)
        var weights = [[Double]](repeating: [Double](repeating: 0, count: refIds.count), count: hypIds.count)
        for f in 0..<frames {
            for h in hyp[f] where !unmappable.contains(hypIds[h]) {
                for r in ref[f] { weights[h][r] += 1 }
            }
        }
        let mapping = optimalMapping(weights)
        var miss = 0, falseAlarm = 0, confusion = 0, speech = 0
        for f in 0..<frames {
            let nRef = ref[f].count
            let nHyp = hyp[f].count
            speech += nRef
            let correct = hyp[f].filter { h in mapping[h].map { ref[f].contains($0) } ?? false }.count
            miss += max(0, nRef - nHyp)
            falseAlarm += max(0, nHyp - nRef)
            confusion += min(nRef, nHyp) - correct
        }
        guard speech > 0 else { return DER() }
        let s = Double(speech)
        return DER(miss: Double(miss) / s, falseAlarm: Double(falseAlarm) / s, confusion: Double(confusion) / s)
    }

    /// Best one-to-one assignment (rows → columns) maximizing total weight.
    /// Exact DP over column subsets; fine for a handful of speakers.
    static func optimalMapping(_ weights: [[Double]]) -> [Int?] {
        let rows = weights.count
        let cols = weights.first?.count ?? 0
        guard rows > 0, cols > 0 else { return [Int?](repeating: nil, count: rows) }
        precondition(cols <= 16)
        var memo: [Int: (Double, [Int?])] = [:]
        func best(_ row: Int, _ used: Int) -> (Double, [Int?]) {
            if row == rows { return (0, []) }
            let key = row << 16 | used
            if let hit = memo[key] { return hit }
            var answer = best(row + 1, used)
            answer.1.insert(nil, at: 0)
            for col in 0..<cols where used & (1 << col) == 0 && weights[row][col] > 0 {
                var candidate = best(row + 1, used | (1 << col))
                candidate.0 += weights[row][col]
                candidate.1.insert(col, at: 0)
                if candidate.0 > answer.0 { answer = candidate }
            }
            memo[key] = answer
            return answer
        }
        return best(0, 0).1
    }

    static func regions(where turns: [R.Turn], without other: [R.Turn], length: Int) -> [Range<Int>] {
        var mask = [Bool](repeating: false, count: length)
        for turn in turns {
            let a = max(0, Int(turn.start * 16_000)), b = min(length, Int(turn.end * 16_000))
            if a < b { for i in a..<b { mask[i] = true } }
        }
        for turn in other {
            // A little slack around the other side's speech.
            let a = max(0, Int((turn.start - 0.3) * 16_000)), b = min(length, Int((turn.end + 0.3) * 16_000))
            if a < b { for i in a..<b { mask[i] = false } }
        }
        var ranges: [Range<Int>] = []
        var i = 0
        while i < length {
            guard mask[i] else { i += 1; continue }
            let s = i
            while i < length && mask[i] { i += 1 }
            ranges.append(s..<i)
        }
        return ranges
    }

    static func energyRatioDB(_ a: [Float], _ b: [Float], over ranges: [Range<Int>]) -> Double {
        var ea = 0.0, eb = 0.0
        for range in ranges {
            for i in range where i < a.count && i < b.count {
                ea += Double(a[i] * a[i])
                eb += Double(b[i] * b[i])
            }
        }
        return 10 * log10(max(ea, 1e-12) / max(eb, 1e-12))
    }

    // MARK: - Fixtures

    static func loadWav(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func parseRTTM(_ url: URL) throws -> [R.Turn] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 8, f[0] == "SPEAKER", let start = Double(f[3]), let dur = Double(f[4]) else { return nil }
            return R.Turn(speakerId: String(f[7]), start: start, end: start + dur)
        }
    }

    /// Direct path 25 ms late (speaker → mic plus device latency), two early
    /// reflections, and a ~250 ms decaying diffuse tail.
    static func roomImpulseResponse() -> [Float] {
        var ir = [Float](repeating: 0, count: 4_800)
        ir[400] = 1
        ir[560] = 0.45
        ir[880] = -0.3
        var rng = Lcg(seed: 3)
        for i in 900..<ir.count {
            let t = Float(i - 900) / 16_000
            ir[i] += 0.12 * rng.nextGaussian() * expf(-t / 0.06)
        }
        return ir
    }

    static func convolve(_ signal: [Float], _ ir: [Float]) -> [Float] {
        // vDSP_conv correlates; reverse the kernel and pad the front.
        let padded = [Float](repeating: 0, count: ir.count - 1) + signal
        var out = [Float](repeating: 0, count: signal.count)
        let kernel = Array(ir.reversed())
        vDSP_conv(padded, 1, kernel, 1, &out, 1, vDSP_Length(signal.count), vDSP_Length(ir.count))
        return out
    }

    static func rms(_ x: [Float]) -> Float {
        guard !x.isEmpty else { return 0 }
        var sum: Float = 0
        for s in x { sum += s * s }
        return (sum / Float(x.count)).squareRoot()
    }

    static func physFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    static func write(_ report: [String: Any], named name: String, in dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appendingPathComponent("results-\(name).json"))
        print("SPEEK_BENCH \(name): \(String(decoding: data, as: UTF8.self))")
    }
}

/// Deterministic noise for the synthetic room.
private struct Lcg {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
    mutating func nextGaussian() -> Float {
        let u1 = max(next(), 1e-7), u2 = next()
        return (-2 * logf(u1)).squareRoot() * cosf(2 * .pi * u2)
    }
}

private extension Dictionary where Key == String, Value == Any {
    static func + (lhs: Self, rhs: Self) -> Self { lhs.merging(rhs) { _, new in new } }
}
