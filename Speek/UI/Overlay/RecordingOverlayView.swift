import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var session: DictationSession
    @ObservedObject var learner = CorrectionLearner.shared

    var body: some View {
        VStack(spacing: 8) {
            if showPreview {
                previewBox
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            ZStack {
                statusPill
                    .opacity(session.state == .idle ? 0 : 1)
                if let learned = learner.lastLearned, session.state == .idle {
                    learnedPill(for: learned)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.easeInOut(duration: 0.18), value: session.state)
        .animation(.easeInOut(duration: 0.18), value: learner.lastLearned)
        .animation(.easeInOut(duration: 0.15), value: showPreview)
    }

    /// Live rolling transcript while recording (and during processing, so the
    /// words don't vanish the instant the key is released).
    private var showPreview: Bool {
        guard !session.partialText.isEmpty else { return false }
        return session.state == .recording || session.state == .processing
    }

    private var previewBox: some View {
        Text(session.partialText)
            .font(.system(size: 13, weight: .regular, design: .rounded))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(3)
            // Head truncation: when the transcript outgrows three lines, the
            // beginning truncates and the newest words stay visible — the tail
            // is what the user needs to confirm they're being heard correctly.
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 440, alignment: .leading)
            .background(.black.opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(radius: 8)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            statusIcon
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 16, height: 16)
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
        .clipShape(Capsule())
        .shadow(radius: 8)
    }

    private func learnedPill(for diff: CorrectionLearner.WordDiff) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
            (
                Text("Learned ")
                    .foregroundStyle(.white.opacity(0.75))
                + Text("“\(diff.original)” → “\(diff.replacement)”")
                    .foregroundStyle(.white)
            )
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.78))
        .clipShape(Capsule())
        .shadow(radius: 8)
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.state {
        case .recording:
            LevelMeter(level: session.audioLevel)
        case .processing:
            ProgressView().controlSize(.small)
        case .inserting:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white)
        case .copied:
            Image(systemName: "doc.on.clipboard.fill").foregroundStyle(.white)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle:
            EmptyView()
        }
    }

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
                        .frame(width: 2, height: heightForBar(i, level: level))
                        .opacity(active ? 1 : 0.35)
                }
            }
            .frame(width: 16, height: 16)
            .animation(.linear(duration: 0.08), value: level)
        }

        /// Each bar grows from a baseline so the meter looks like an EQ display.
        private func heightForBar(_ i: Int, level: Float) -> CGFloat {
            let base: CGFloat = 4
            let max: CGFloat = 14
            let weight: CGFloat = i == 1 || i == 2 ? 1.0 : 0.7
            let scaled = base + CGFloat(level) * (max - base) * weight
            return min(max, scaled)
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return ""
        case .recording: return "Listening…"
        case .processing: return "Processing…"
        case .inserting: return "Inserting"
        case .copied: return "Copied to clipboard"
        case .error(let msg): return msg
        }
    }
}
