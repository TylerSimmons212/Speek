import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Compact recording indicator while meeting transcription runs: the notch
/// expands slightly OUTWARD (iPhone call-indicator style) — a red dot on the
/// leading side, a live level meter trailing. Hovering expands to show the
/// elapsed time and a Stop button.
///
/// Yields to the dictation overlay (which uses the expanded notch) and
/// returns once dictation finishes.
@MainActor
final class MeetingIndicatorController {
    private let notch: DynamicNotch<MeetingIndicatorExpandedView, MeetingIndicatorDotView, MeetingIndicatorMeterView>
    private var cancellables = Set<AnyCancellable>()
    private let service: MeetingTranscriptionService
    private let session: DictationSession

    init(service: MeetingTranscriptionService, session: DictationSession) {
        self.service = service
        self.session = session
        self.notch = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .auto
        ) {
            MeetingIndicatorExpandedView(service: service)
        } compactLeading: {
            MeetingIndicatorDotView()
        } compactTrailing: {
            MeetingIndicatorMeterView(service: service)
        }

        // Show/hide with the meeting session…
        service.$state
            .map { state -> Bool in
                if case .listening = state { return true }
                return false
            }
            .removeDuplicates()
            .sink { [weak self] listening in
                guard let self else { return }
                Task {
                    if listening, session.state == .idle {
                        await self.show()
                    } else if !listening {
                        await self.notch.hide()
                    }
                }
            }
            .store(in: &cancellables)

        // …and yield the notch to the dictation overlay while it's active.
        session.$state
            .map { $0 == .idle }
            .removeDuplicates()
            .sink { [weak self] dictationIdle in
                guard let self else { return }
                Task {
                    if dictationIdle, service.isListening {
                        // Give the dictation overlay's collapse animation room.
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard service.isListening, session.state == .idle else { return }
                        await self.show()
                    } else if !dictationIdle {
                        service.livePreviewActive = false
                        await self.notch.hide()
                    }
                }
            }
            .store(in: &cancellables)

        // Hover: compact indicator expands downward into a live transcript
        // (and live decoding runs only while the user is actually looking).
        notch.$isHovering
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self else { return }
                guard service.isListening, session.state == .idle else { return }
                Task {
                    if hovering {
                        service.livePreviewActive = true
                        await self.expand()
                    } else {
                        service.livePreviewActive = false
                        await self.show() // back to compact
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func expand() async {
        guard let screen = Self.targetScreen() else { return }
        let exclusion = Task { await excludeFromScreenCapture() }
        await notch.expand(on: screen)
        await exclusion.value
    }

    /// The live transcript is personal content — keep it out of screen
    /// shares and recordings. The exclusion must land BEFORE the fade-in, so
    /// this polls for the (recreated-per-show) window and flags it within
    /// ~10ms of creation, while it's still at zero opacity.
    private func excludeFromScreenCapture() async {
        for _ in 0..<50 {
            if let window = notch.windowController?.window {
                window.sharingType = .none
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func show() async {
        guard let screen = Self.targetScreen() else { return }
        // Compact flanks the notch on notched screens; on screens without
        // one, DynamicNotchKit hides compact-only content — acceptable, the
        // menu bar item still shows the running state there.
        let exclusion = Task { await excludeFromScreenCapture() }
        await notch.compact(on: screen)
        await exclusion.value
    }

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
    }
}

// MARK: - Views

struct MeetingIndicatorDotView: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 8, height: 8)
            .opacity(pulsing ? 0.5 : 1)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .padding(.horizontal, 2)
    }
}

struct MeetingIndicatorMeterView: View {
    @ObservedObject var service: MeetingTranscriptionService

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(0..<3, id: \.self) { i in
                let threshold = Float(i + 1) / 3
                Capsule()
                    .fill(.white)
                    .frame(width: 2, height: 4 + CGFloat(min(service.audioLevel, threshold)) * 8)
                    .opacity(service.audioLevel >= threshold * 0.4 ? 1 : 0.35)
            }
        }
        .animation(.linear(duration: 0.12), value: service.audioLevel)
        .padding(.horizontal, 2)
    }
}

struct MeetingIndicatorExpandedView: View {
    @ObservedObject var service: MeetingTranscriptionService
    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle().fill(.red).frame(width: 9, height: 9)
                Text("Transcribing meeting")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                Text(elapsedLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 12)
                Button {
                    Task { @MainActor in
                        if let url = await service.stop() {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                } label: {
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(0.2)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
            }

            // Live transcript: recent finished segments + the in-flight
            // window's rolling decode. Newest words stay visible.
            Text(recentTranscript.isEmpty ? "Listening…" : recentTranscript)
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(recentTranscript.isEmpty ? .white.opacity(0.4) : .white.opacity(0.85))
                .lineLimit(5)
                .truncationMode(.head)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.25), value: recentTranscript)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
        .onReceive(tick) { now = $0 }
    }

    private var recentTranscript: String {
        var parts = service.segments.suffix(2).map(\.text)
        if !service.livePartial.isEmpty { parts.append(service.livePartial) }
        return parts.joined(separator: " ")
    }

    private var elapsedLabel: String {
        MeetingTranscriptionService.timestamp(now.timeIntervalSince(
            {
                if case .listening(let since) = service.state { return since }
                return now
            }()
        ))
    }
}
