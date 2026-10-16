import Accelerate
import FluidAudio
import Foundation

/// Append-only on-disk copy of a meeting's 16 kHz system-audio ("Them")
/// track, kept so the whole session can be re-diarized offline at stop.
///
/// Stored as raw Int16 PCM in a temp file: 32 KB per second of audio, so an
/// hour-long call costs ~115 MB of temp disk and nothing resident in RAM
/// (the offline pass reads it back through a memory map).
///
/// Sample index N in the spool is sample N of the session's system track —
/// the same timeline `MeetingTranscriptionService` uses for segment spans.
final class SystemTrackSpool {
    static let sampleRate = 16_000

    let url: URL
    private var handle: FileHandle?
    private(set) var sampleCount = 0
    /// A write failed (disk full, file yanked). The spool stops accepting
    /// audio and `finish()` returns nil so the caller keeps live labels.
    private(set) var failed = false

    init?(directory: URL = FileManager.default.temporaryDirectory) {
        let url = directory.appendingPathComponent("speek-meeting-\(UUID().uuidString).pcm16")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        self.url = url
        self.handle = handle
    }

    deinit {
        try? handle?.close()
        try? FileManager.default.removeItem(at: url)
    }

    var duration: TimeInterval { Double(sampleCount) / Double(Self.sampleRate) }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty, !failed, let handle else { return }
        let data = Self.pcm16Data(from: samples)
        do {
            try handle.write(contentsOf: data)
            sampleCount += samples.count
        } catch {
            NSLog("SystemTrackSpool: write failed, offline relabel disabled — \(error)")
            failed = true
        }
    }

    /// Closes the file for writing and maps it for reading. Nil when nothing
    /// was recorded or a write failed. The spool keeps owning the file: the
    /// mapping stays valid until the spool is released (unlinking a mapped
    /// file doesn't invalidate the mapping), and deinit deletes it.
    func finish() -> MappedPCM16Source? {
        try? handle?.close()
        handle = nil
        guard !failed, sampleCount > 0,
              let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            return nil
        }
        return MappedPCM16Source(data: data)
    }

    static func pcm16Data(from samples: [Float]) -> Data {
        var ints = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let scaled = (samples[i] * 32_767).rounded()
            ints[i] = Int16(max(-32_768, min(32_767, scaled)))
        }
        return ints.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Read-only Float view over memory-mapped Int16 PCM, fed straight into
/// FluidAudio's offline diarizer so the full track never materializes as a
/// `[Float]` (which would be ~230 MB for an hour).
struct MappedPCM16Source: AudioSampleSource {
    private let data: Data
    let sampleCount: Int

    init(data: Data) {
        self.data = data
        self.sampleCount = data.count / MemoryLayout<Int16>.stride
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        guard count > 0, sampleCount > 0 else { return }
        let start = max(0, offset)
        guard start < sampleCount else { return }
        let available = min(sampleCount - start, count)
        data.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            vDSP_vflt16(ints.baseAddress! + start, 1, destination, 1, vDSP_Length(available))
            var scale: Float = 1.0 / 32_768
            vDSP_vsmul(destination, 1, &scale, destination, 1, vDSP_Length(available))
        }
    }
}
