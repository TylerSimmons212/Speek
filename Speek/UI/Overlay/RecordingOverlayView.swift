import SwiftUI

struct RecordingOverlayView: View {
    @ObservedObject var session: DictationSession

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            Text(statusText)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.black.opacity(0.7))
        .clipShape(Capsule())
        .shadow(radius: 8)
        .opacity(session.state == .idle ? 0 : 1)
        .animation(.easeInOut(duration: 0.18), value: session.state)
    }

    @ViewBuilder private var statusIcon: some View {
        switch session.state {
        case .recording:
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)
                .foregroundStyle(.red)
        case .processing:
            ProgressView().controlSize(.small)
        case .inserting:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
        case .idle:
            EmptyView()
        }
    }

    private var statusText: String {
        switch session.state {
        case .idle: return ""
        case .recording: return "Listening…"
        case .processing: return "Processing…"
        case .inserting: return "Inserting"
        case .error(let msg): return msg
        }
    }
}
