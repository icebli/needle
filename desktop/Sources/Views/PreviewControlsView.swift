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
                    Text("Preparing a full-track preview…")
                    Spacer()
                    Button("Cancel") { service.stop() }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                } else if isCurrent, case .failed(let message) = service.state {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(message).lineLimit(2)
                    Spacer()
                    Button("Retry") { service.retry(candidate: candidate) }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Button {
                                if isCurrent { service.togglePlayback() } else { service.start(candidate: candidate) }
                            } label: {
                                Label(isCurrent && service.isPlaying ? "Pause preview" : isCurrent ? "Play preview" : "Preview recording",
                                      systemImage: isCurrent && service.isPlaying ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.bordered)
                            if isCurrent {
                                Text("\(format(service.elapsed)) / \(format(service.duration))")
                                    .monospacedDigit().foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("Stop") { service.stop() }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                        }
                        if isCurrent {
                            Slider(value: value, in: 0...max(service.duration, 0.1))
                                .accessibilityLabel("Preview position")
                            HStack(spacing: 12) {
                                Button("−10") { service.seek(by: -10) }
                                Button("+10") { service.seek(by: 10) }
                                Button("Skip intro") { service.skipIntro() }
                            }
                            .buttonStyle(.borderless)
                            .disabled(service.isPreparing)
                        }
                    }
                }
            }
            if isCurrent, !service.isPreparing, service.duration > 0 {
                HStack(spacing: 12) {
                    Toggle("Keep position when switching sources", isOn: $service.keepTimestampAcrossCandidates)
                        .toggleStyle(.checkbox)
                    Text("Full track · temporary")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(.leading, 2)
            }
            if isCurrent, case .failed = service.state {
                Text("Needle keeps previews temporary and does not save them to your library.")
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
