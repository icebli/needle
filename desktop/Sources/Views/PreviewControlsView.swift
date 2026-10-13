import SwiftUI

struct PreviewControlsView: View {
    @ObservedObject var service: AudioPreviewService
    let candidate: CandidateResult

    private var isCurrent: Bool { service.candidateID == candidate.id }
    private var value: Binding<Double> {
        Binding(get: { service.elapsed }, set: { service.seek(to: $0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Preview", systemImage: "headphones")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isCurrent && service.isPreparing {
                    ProgressView().controlSize(.small)
                    Text("Preparing a 30-second preview…")
                    Spacer()
                    Button("Cancel") { service.stop() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else if isCurrent, case .failed(let message) = service.state {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Retry") { service.retry(candidate: candidate) }
                } else {
                    Button {
                        if isCurrent { service.togglePlayback() } else { service.start(candidate: candidate) }
                    } label: {
                        Label(isCurrent && service.isPlaying ? "Pause preview" : isCurrent ? "Play preview" : "Preview 30 sec",
                              systemImage: isCurrent && service.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.bordered)
                    if isCurrent {
                        Slider(value: value, in: 0...max(service.duration, 0.1))
                            .frame(maxWidth: 260)
                            .accessibilityLabel("Preview position")
                        Text("\(format(service.elapsed)) / \(format(service.duration))")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Button("Stop") { service.stop() }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
            if isCurrent, case .failed = service.state {
                Text("Needle keeps the preview temporary and does not save it to your library.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
            } else {
                RoundedRectangle(cornerRadius: 12).fill(.quaternary.opacity(0.45))
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}
