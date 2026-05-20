import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var session: DictationSession
    @ObservedObject var learner = CorrectionLearner.shared

    var body: some View {
        ZStack {
            statusPill
                .opacity(session.state == .idle ? 0 : 1)
            if let learned = learner.lastLearned, session.state == .idle {
                learnedPill(for: learned)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .animation(.easeInOut(duration: 0.18), value: session.state)
        .animation(.easeInOut(duration: 0.18), value: learner.lastLearned)
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
