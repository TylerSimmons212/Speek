import AppKit
import Combine
import DynamicNotchKit
import SwiftUI

/// Dynamic Island-style overlay: the dictation UI fluidly expands out of the
/// MacBook notch (or a floating top-center window on screens without one).
/// Drives a DynamicNotchKit window from DictationSession state — the SwiftUI
/// content itself observes the session, so this controller only decides
/// *when* the notch is visible, never what's inside it.
@MainActor
final class NotchOverlayController {
    private let notch: DynamicNotch<NotchOverlayView, EmptyView, EmptyView>
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?

    init(session: DictationSession) {
        // hoverBehavior .keepVisible keeps the notch open while the mouse is
        // over it — required so the "Learned" pill's undo button is clickable
        // before the auto-hide fires.
        self.notch = DynamicNotch(hoverBehavior: [.keepVisible], style: .auto) {
            NotchOverlayView(session: session)
        }

        session.$state
            .removeDuplicates()
            .sink { [weak self] state in self?.react(to: state) }
            .store(in: &cancellables)

        // The learned-word pill shows after the session is back to idle, so it
        // needs its own visibility trigger.
        CorrectionLearner.shared.$lastLearned
            .removeDuplicates()
            .sink { [weak self] learned in
                guard let self else { return }
                if learned != nil {
                    self.hideTask?.cancel()
                    Task { await self.show() }
                } else if session.state == .idle {
                    self.scheduleHide(afterMs: 150)
                }
            }
            .store(in: &cancellables)
    }

    /// Closes the notch window immediately. Called when the user switches to
    /// the bottom-pill overlay style so the two never coexist.
    func dismiss() {
        hideTask?.cancel()
        hideTask = nil
        Task { await notch.hide() }
    }

    private func react(to state: DictationSession.State) {
        hideTask?.cancel()
        switch state {
        case .recording, .processing, .inserting, .copied, .error:
            Task { await show() }
        case .idle:
            // Small grace period: .inserting → .idle transitions arrive fast,
            // and if a "learned" pill is about to appear we shouldn't flap.
            scheduleHide(afterMs: 250)
        }
    }

    private func show() async {
        guard let screen = Self.targetScreen() else { return }
        // Exclusion must land BEFORE the window fades in (setting it after
        // expand() returns leaves a ~0.4s window where recordings capture the
        // overlay). Race a poll against the window's creation: it exists
        // within milliseconds of expand() starting, still at zero opacity.
        let exclusion = Task { await Self.excludeFromCapture(notch: notch) }
        await notch.expand(on: screen)
        await exclusion.value
    }

    private static func excludeFromCapture(
        notch: DynamicNotch<NotchOverlayView, EmptyView, EmptyView>
    ) async {
        for _ in 0..<50 {
            if let window = notch.windowController?.window {
                window.sharingType = .none
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private func scheduleHide(afterMs ms: UInt64) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: ms * 1_000_000)
            guard let self, !Task.isCancelled else { return }
            guard CorrectionLearner.shared.lastLearned == nil else { return }
            await self.notch.hide()
        }
    }

    /// The screen the user is working on — where the mouse is — falling back
    /// to the first screen. DynamicNotchKit renders notch-style on notched
    /// screens and a floating top-center window elsewhere.
    private static func targetScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
    }
}

// MARK: - Content

/// Expanded notch content. Black background comes from the notch shape itself,
/// so everything here is drawn white-on-black.
struct NotchOverlayView: View {
    @ObservedObject var session: DictationSession
    @ObservedObject var learner = CorrectionLearner.shared

    var body: some View {
        VStack(spacing: 8) {
            headerRow
            if showTranscript {
                transcriptText
            }
            if let learned = learner.lastLearned, session.state == .idle {
                learnedRow(learned)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(width: 340)
        .animation(.smooth(duration: 0.25), value: session.partialText)
        .animation(.smooth(duration: 0.25), value: session.state)
    }

    private var showTranscript: Bool {
        guard !session.partialText.isEmpty else { return false }
        return session.state == .recording || session.state == .processing
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18, height: 18)
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 0)
            if session.state == .recording {
                LevelMeter(level: session.audioLevel)
                    .frame(width: 22, height: 16)
            }
        }
    }

    private var transcriptText: some View {
        Text(session.partialText)
            .font(.system(size: 12.5, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(4)
            // Newest words matter most — truncate the beginning, keep the tail.
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func learnedRow(_ diff: CorrectionLearner.WordDiff) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
            (
                Text("Learned ")
                    .foregroundStyle(.white.opacity(0.75))
                + Text("“\(diff.original)” → “\(diff.replacement)”")
                    .foregroundStyle(.white)
            )
            .font(.system(size: 12.5, weight: .medium, design: .rounded))
            .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                learner.undoLastLearned()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.white.opacity(0.65))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .help("Undo and don't learn this")
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.state {
        case .recording:
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
                .font(.system(size: 13, weight: .semibold))
        case .processing:
            ProgressView().controlSize(.small).tint(.white)
        case .inserting:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 13, weight: .semibold))
        case .copied:
            Image(systemName: "doc.on.clipboard.fill")
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 13, weight: .semibold))
        case .idle:
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return "Speek"
        case .recording: return "Listening…"
        case .processing: return "Processing…"
        case .inserting: return "Inserting"
        case .copied: return "Copied to clipboard"
        case .error(let msg): return msg
        }
    }

    /// EQ-style level meter, white bars on the notch's black background.
    private struct LevelMeter: View {
        let level: Float
        private let bars = 4
        var body: some View {
            HStack(spacing: 2) {
                ForEach(0..<bars, id: \.self) { i in
                    let threshold = Float(i + 1) / Float(bars)
                    let active = level >= threshold * 0.5
                    Capsule()
                        .fill(.white)
                        .frame(width: 2.5, height: heightForBar(i, level: level))
                        .opacity(active ? 1 : 0.35)
                }
            }
            .animation(.linear(duration: 0.08), value: level)
        }

        private func heightForBar(_ i: Int, level: Float) -> CGFloat {
            let base: CGFloat = 4
            let max: CGFloat = 14
            let weight: CGFloat = i == 1 || i == 2 ? 1.0 : 0.7
            let scaled = base + CGFloat(level) * (max - base) * weight
            return min(max, scaled)
        }
    }
}
