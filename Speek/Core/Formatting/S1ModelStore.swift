import Combine
import Foundation

/// Downloads and locates the s1-mini weights ("S1-mini" by Superwhisper,
/// Apache 2.0 with a naming clause) — the official Q4_K_M GGUF, ~484 MB.
/// Same pattern as FluidAudio's Parakeet download: pulled once on first use,
/// cached locally, reused forever after.
@MainActor
final class S1ModelStore: ObservableObject {
    static let shared = S1ModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(progress: Double) // 0…1
        case ready
        case failed(String)
    }

    @Published private(set) var state: State

    private nonisolated static let downloadURL = URL(
        string: "https://huggingface.co/superwhisper/s1-mini-GGUF/resolve/main/s1-mini-q4_k_m.gguf"
    )!

    nonisolated static var modelURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Speek/Models/s1-mini-q4_k_m.gguf")
    }

    nonisolated static var isModelPresent: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    private var downloadTask: Task<Void, Never>?

    private init() {
        state = Self.isModelPresent ? .ready : .notDownloaded
    }

    /// Starts the download if the weights aren't on disk yet. Safe to call
    /// repeatedly — a download already in flight is left alone.
    func ensureDownloaded() {
        guard downloadTask == nil, state != .ready else { return }
        guard !Self.isModelPresent else {
            state = .ready
            return
        }
        state = .downloading(progress: 0)
        downloadTask = Task { [weak self] in
            do {
                try await Self.download { progress in
                    Task { @MainActor in Self.shared.noteProgress(progress) }
                }
                self?.state = .ready
                NSLog("S1ModelStore: s1-mini downloaded to \(Self.modelURL.path)")
            } catch {
                self?.state = .failed(error.localizedDescription)
                NSLog("S1ModelStore: download failed — \(error.localizedDescription)")
            }
            self?.downloadTask = nil
        }
    }

    private func noteProgress(_ progress: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: progress)
    }

    func retry() {
        guard case .failed = state else { return }
        state = .notDownloaded
        ensureDownloaded()
    }

    /// Downloads to a temp file with progress, validates the GGUF magic, then
    /// moves into place atomically-enough (rename within the same volume).
    private nonisolated static func download(
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let observation = ObservationBox()
        defer { observation.cancel() }
        let downloaded: URL = try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: downloadURL) { location, response, error in
                // Completion handler runs exactly once; `location` is only
                // valid inside it, so stage the file before resuming.
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let location,
                      let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode) else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent("s1-mini-\(UUID().uuidString).gguf")
                do {
                    try FileManager.default.moveItem(at: location, to: staged)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation.observe(task.progress) { fraction in
                onProgress(fraction)
            }
            task.resume()
        }

        // Sanity-check we got model weights, not an HTML error page.
        let handle = try FileHandle(forReadingFrom: downloaded)
        let magic = try handle.read(upToCount: 4)
        try handle.close()
        guard magic == Data("GGUF".utf8) else {
            try? FileManager.default.removeItem(at: downloaded)
            throw URLError(.cannotParseResponse)
        }

        let dest = modelURL
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: downloaded, to: dest)
    }

    /// Holds the KVO observation on `Progress` for the lifetime of the
    /// download without capturing it in the continuation closure.
    private final class ObservationBox: @unchecked Sendable {
        private var observation: NSKeyValueObservation?
        func observe(_ progress: Progress, _ handler: @escaping @Sendable (Double) -> Void) {
            observation = progress.observe(\.fractionCompleted) { progress, _ in
                handler(progress.fractionCompleted)
            }
        }
        func cancel() { observation?.invalidate() }
    }
}
