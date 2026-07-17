import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Notch mini-player while Speek reads text aloud. Expands with playback
/// controls and a karaoke-style transcript when speech starts, settles into
/// a compact indicator (animated speaker + progress ring) after a moment,
/// and re-expands on hover — same choreography as the meeting indicator.
@MainActor
final class SpeechOverlayController {
    private let notch: DynamicNotch<SpeechPlayerView, SpeechCompactIconView, SpeechCompactProgressView>
    private var cancellables = Set<AnyCancellable>()
    private let speech: SpeechService
    private var settleTask: Task<Void, Never>?

    init(speech: SpeechService = .shared) {
        self.speech = speech
        // Forced .notch: flat screens get the same virtual notch as the rest
        // of Speek's overlays.
        self.notch = DynamicNotch(
            hoverBehavior: [.keepVisible, .increaseShadow],
            style: .notch
        ) {
            SpeechPlayerView(speech: speech)
        } compactLeading: {
            SpeechCompactIconView(speech: speech)
        } compactTrailing: {
            SpeechCompactProgressView(speech: speech)
        }

        // Show while speaking; the initial expanded moment gives the user the
        // controls right when they triggered the read, then we get out of
        // the way.
        speech.$state
            .map { $0 != .idle }
            .removeDuplicates()
            .sink { [weak self] speaking in
                guard let self else { return }
                self.settleTask?.cancel()
                Task {
                    if speaking {
                        await self.expand()
                        self.scheduleSettle()
                    } else {
                        await self.notch.hide()
                    }
                }
            }
            .store(in: &cancellables)

        notch.$isHovering
            .removeDuplicates()
            .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
            .sink { [weak self] hovering in
                guard let self, self.speech.isSpeaking else { return }
                self.settleTask?.cancel()
                Task {
                    if hovering {
                        await self.expand()
                    } else {
                        await self.compact()
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func scheduleSettle() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard let self, !Task.isCancelled, self.speech.isSpeaking else { return }
            guard !self.notch.isHovering else { return }
            await self.compact()
        }
    }

    private func expand() async {
        guard let screen = Self.targetScreen() else { return }
        let exclusion = Task { await excludeFromScreenCapture() }
        await notch.expand(on: screen)
        await exclusion.value
    }

    private func compact() async {
        guard let screen = Self.targetScreen() else { return }
        let exclusion = Task { await excludeFromScreenCapture() }
        await notch.compact(on: screen)
        await exclusion.value
    }

    /// What's being read could be anything on the user's screen — keep it out
    /// of screen shares and recordings, flagged before the fade-in.
    private func excludeFromScreenCapture() async {
        for _ in 0..<50 {
            if let window = notch.windowController?.window {
                window.sharingType = .none
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
    }
}

// MARK: - Compact views

struct SpeechCompactIconView: View {
    @ObservedObject var speech: SpeechService

    var body: some View {
        Image(systemName: paused ? "pause.fill" : "speaker.wave.2.fill")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !paused)
            .padding(.horizontal, 2)
    }

    private var paused: Bool { speech.state == .speaking(paused: true) }
}

struct SpeechCompactProgressView: View {
    @ObservedObject var speech: SpeechService

    var body: some View {
        Circle()
            .stroke(.white.opacity(0.25), lineWidth: 2)
            .overlay(
                Circle()
                    .trim(from: 0, to: max(0.03, speech.progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            )
            .frame(width: 9, height: 9)
            .animation(.linear(duration: 0.2), value: speech.progress)
            .padding(.horizontal, 2)
    }
}

// MARK: - Expanded mini-player

struct SpeechPlayerView: View {
    @ObservedObject var speech: SpeechService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if isPreparing {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.white)
                        .font(.system(size: 13, weight: .semibold))
                        .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !isPaused)
                }
                Text(isPreparing ? "Preparing voice…" : (isPaused ? "Paused" : "Reading aloud"))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 12)
                if !isPreparing {
                    Button {
                        speech.pauseOrResume()
                    } label: {
                        Image(systemName: isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(.white.opacity(0.2)))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .pointerStyle(.link)
                }
                Button {
                    speech.stop()
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

            // Karaoke transcript: the word being spoken glows; dimmed context
            // around it. The window slides so the highlight never scrolls
            // out of view on long passages.
            Text(karaokeText)
                .font(.system(size: 12.5, design: .rounded))
                .lineLimit(4)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.smooth(duration: 0.2), value: speech.spokenRange)

            // Thin progress bar along the bottom.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white.opacity(0.7))
                        .frame(width: max(3, geo.size.width * speech.progress))
                }
            }
            .frame(height: 3)
            .animation(.linear(duration: 0.2), value: speech.progress)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 380)
    }

    private var isPaused: Bool { speech.state == .speaking(paused: true) }
    private var isPreparing: Bool { speech.state == .preparing }

    private var karaokeText: AttributedString {
        let slice = SpokenTextWindow.slice(text: speech.currentText, spokenRange: speech.spokenRange)
        var before = AttributedString(slice.before)
        before.foregroundColor = .white.opacity(0.5)
        var current = AttributedString(slice.current)
        current.foregroundColor = .white
        current.font = .system(size: 12.5, weight: .semibold, design: .rounded)
        var after = AttributedString(slice.after)
        after.foregroundColor = .white.opacity(0.5)
        return before + current + after
    }
}
