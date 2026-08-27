import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

/// Captures the Mac's system audio output (what's playing through the
/// speakers — every app's sound, including video calls) using a Core Audio
/// process tap. No virtual drivers, no joining calls: this is the same
/// mechanism Screen Sharing uses, gated behind the "System Audio Recording"
/// permission (first start triggers the prompt via
/// NSAudioCaptureUsageDescription).
///
/// Audio arrives on a realtime thread; this service downmixes to mono
/// immediately (cheap) and hands fixed batches of Float samples plus the
/// native sample rate to the consumer on a normal thread via a locked buffer.
final class SystemAudioTapService: @unchecked Sendable {
    enum TapError: Error, LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case formatUnavailable(OSStatus)
        case ioProcFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let s): return "Couldn't create the system audio tap (\(s)). Check System Audio Recording permission in System Settings → Privacy & Security → Screen & System Audio Recording."
            case .aggregateCreationFailed(let s): return "Couldn't create the capture device (\(s))."
            case .formatUnavailable(let s): return "Couldn't read the tap's audio format (\(s))."
            case .ioProcFailed(let s): return "Couldn't start audio capture (\(s))."
            }
        }
    }

    /// Mono Float samples at `sampleRate`, drained by the consumer.
    private let bufferLock = NSLock()
    private var pendingSamples: [Float] = []

    private(set) var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var running = false

    var isRunning: Bool { running }

    // MARK: - Lifecycle

    func start() throws {
        guard !running else { return }

        // 1. System-wide tap (all processes' output, mixed to stereo).
        //    Private so other apps can't see it; unmuted so the user still
        //    hears their call.
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Speek Meeting Transcription"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // 2. The tap's stream format (typically 48kHz stereo Float32).
        var formatAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let formatStatus = AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &asbd)
        guard formatStatus == noErr, asbd.mSampleRate > 0 else {
            cleanupTap()
            throw TapError.formatUnavailable(formatStatus)
        }
        sampleRate = asbd.mSampleRate
        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        // Non-interleaved streams deliver one AudioBuffer per channel;
        // treating them as interleaved would drop every channel but the
        // first and garble the mono downmix.
        let interleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0

        // 3. A private aggregate device wrapping the tap — the only way to
        //    run an IO proc against tap audio.
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "Speek System Audio",
            kAudioAggregateDeviceUIDKey as String: "com.tylersimmons.Speek.systemtap." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapUIDKey as String: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey as String: true
                ]
            ]
        ]
        var newAggregateID = AudioObjectID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            cleanupTap()
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggregateID

        // 4. IO proc: runs on a realtime thread — do the bare minimum
        //    (downmix to mono, append under lock).
        var newProcID: AudioDeviceIOProcID?
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggregateID, nil) { [weak self] _, inInputData, _, _, _ in
            self?.ingest(bufferList: inInputData, channels: channelCount, interleaved: interleaved)
        }
        guard procStatus == noErr, let procID = newProcID else {
            cleanupAggregate()
            cleanupTap()
            throw TapError.ioProcFailed(procStatus)
        }
        ioProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
            cleanupAggregate()
            cleanupTap()
            throw TapError.ioProcFailed(startStatus)
        }
        running = true
        NSLog("SystemAudioTapService: capturing at \(sampleRate)Hz, \(channelCount)ch")
    }

    func stop() {
        guard running else { return }
        running = false
        if let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        cleanupAggregate()
        cleanupTap()
        bufferLock.lock()
        pendingSamples.removeAll()
        bufferLock.unlock()
    }

    /// Removes and returns all captured mono samples (at `sampleRate`).
    func drain() -> [Float] {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        return samples
    }

    // MARK: - Internals

    private func ingest(bufferList: UnsafePointer<AudioBufferList>, channels: Int, interleaved: Bool) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let mono: [Float]
        if interleaved || buffers.count <= 1 {
            guard let buffer = buffers.first, let data = buffer.mData else { return }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { return }
            let floats = data.bindMemory(to: Float.self, capacity: sampleCount)

            // Downmix interleaved channels to mono.
            let frames = sampleCount / max(1, channels)
            var mixed = [Float](repeating: 0, count: frames)
            if channels == 1 {
                mixed.withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress?.update(from: floats, count: frames)
                }
            } else {
                for frame in 0..<frames {
                    var sum: Float = 0
                    for ch in 0..<channels { sum += floats[frame * channels + ch] }
                    mixed[frame] = sum / Float(channels)
                }
            }
            mono = mixed
        } else {
            // Non-interleaved: one AudioBuffer per channel — average them.
            let channelData: [(UnsafePointer<Float>, Int)] = buffers.compactMap { buffer in
                guard let data = buffer.mData else { return nil }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                guard count > 0 else { return nil }
                return (UnsafePointer(data.bindMemory(to: Float.self, capacity: count)), count)
            }
            guard let frames = channelData.map(\.1).min(), frames > 0 else { return }
            var mixed = [Float](repeating: 0, count: frames)
            for (floats, _) in channelData {
                for frame in 0..<frames { mixed[frame] += floats[frame] }
            }
            let scale = 1 / Float(channelData.count)
            for frame in 0..<frames { mixed[frame] *= scale }
            mono = mixed
        }

        bufferLock.lock()
        pendingSamples.append(contentsOf: mono)
        bufferLock.unlock()
    }

    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    private func cleanupAggregate() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
    }

}

/// Streaming 16kHz mono resampler for the system-audio track. One instance
/// per meeting session: the converter KEEPS its filter state across chunks.
/// The old per-drain approach built a fresh AVAudioConverter (and flushed it
/// with .endOfStream) every 500ms, which reset the resampling filter at
/// every chunk boundary (audible artifacts at 44.1kHz) and truncated
/// fractional samples per call (cumulative drift).
final class StreamResampler {
    let fromRate: Double
    private let converter: AVAudioConverter?
    private let inFormat: AVAudioFormat?
    private let outFormat: AVAudioFormat?

    init(fromRate: Double) {
        self.fromRate = fromRate
        if fromRate == 16_000 {
            converter = nil
            inFormat = nil
            outFormat = nil
            return
        }
        inFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false
        )
        outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        )
        if let inFormat, let outFormat {
            converter = AVAudioConverter(from: inFormat, to: outFormat)
        } else {
            converter = nil
        }
    }

    func resample(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard let converter, let inFormat, let outFormat else { return samples } // already 16k
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return [] }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData?[0].update(from: source.baseAddress!, count: samples.count)
        }
        // One-shot input block (see AudioCaptureService.convertedChunk):
        // .noDataNow, not .endOfStream, so the converter retains state for
        // the next chunk instead of flushing.
        return AudioCaptureService.convertedChunk(
            from: buffer, converter: converter, targetFormat: outFormat
        ) ?? []
    }
}
