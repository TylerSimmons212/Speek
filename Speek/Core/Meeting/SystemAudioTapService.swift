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
            self?.ingest(bufferList: inInputData, channels: channelCount)
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

    private func ingest(bufferList: UnsafePointer<AudioBufferList>, channels: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        guard let buffer = buffers.first,
              let data = buffer.mData else { return }
        let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        guard sampleCount > 0 else { return }
        let floats = data.bindMemory(to: Float.self, capacity: sampleCount)

        // Downmix interleaved channels to mono.
        let frames = sampleCount / max(1, channels)
        var mono = [Float](repeating: 0, count: frames)
        if channels == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: floats, count: frames)
            }
        } else {
            for frame in 0..<frames {
                var sum: Float = 0
                for ch in 0..<channels { sum += floats[frame * channels + ch] }
                mono[frame] = sum / Float(channels)
            }
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

    // MARK: - Resampling helper (consumer-side)

    /// Downsamples mono samples from `fromRate` to 16kHz for Parakeet.
    /// Uses simple averaging when the ratio is integral (48k → 16k is 3:1),
    /// AVAudioConverter otherwise (44.1k etc.).
    static func resampleTo16k(_ samples: [Float], fromRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        if fromRate == 16_000 { return samples }

        let ratio = fromRate / 16_000
        if ratio == ratio.rounded(), ratio >= 1 {
            let step = Int(ratio)
            var out = [Float]()
            out.reserveCapacity(samples.count / step + 1)
            var i = 0
            while i + step <= samples.count {
                var sum: Float = 0
                for j in 0..<step { sum += samples[i + j] }
                out.append(sum / Float(step))
                i += step
            }
            return out
        }

        // Non-integral ratio: proper conversion.
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fromRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return samples
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        let outCapacity = AVAudioFrameCount(Double(samples.count) / ratio + 1)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return samples }
        var fed = false
        converter.convert(to: outBuffer, error: nil) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return inBuffer
        }
        let frames = Int(outBuffer.frameLength)
        guard frames > 0, let channel = outBuffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: frames))
    }
}
