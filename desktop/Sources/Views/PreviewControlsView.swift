import SwiftUI

struct PreviewControlsView: View {
    @ObservedObject var service: AudioPreviewService
    let candidate: CandidateResult
    var showsPositionOption = true
    var settings = NeedleSettings()

    private var isCurrent: Bool { service.candidateID == candidate.id }
    private var isPlayable: Bool {
        isCurrent && [.ready, .playing, .paused].contains(service.state)
    }
    private var value: Binding<Double> {
        Binding(get: { isCurrent ? service.elapsed : 0 }, set: { service.seek(to: $0) })
    }

    var body: some View {
        HStack(spacing: 10) {
            if isCurrent && service.isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 32, height: 32)
                    .help("Preparing the selected recording for preview")
                    .accessibilityLabel("Preparing preview")
            } else if isCurrent, case .failed(let message) = service.state {
                Button { service.start(candidate: candidate, settings: settings) } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityLabel("Retry preview")
                .help("Preview failed: \(message)\nRetry the selected recording.")
            } else {
                Button {
                    if isCurrent { service.togglePlayback() } else { service.start(candidate: candidate, settings: settings) }
                } label: {
                    Image(systemName: isCurrent && service.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.14), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityLabel(isCurrent && service.isPlaying ? "Pause preview" : isCurrent ? "Play preview" : "Preview recording")
                .help(isCurrent && service.isPlaying ? "Pause preview" : "Play the selected recording")
            }

            Text(format(isCurrent ? service.elapsed : 0))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)

            Slider(value: value, in: 0...max(isCurrent ? service.duration : 0, 0.1))
                .disabled(!isPlayable || service.duration <= 0)
                .accessibilityLabel("Preview position")
                .frame(minWidth: 60, maxWidth: .infinity)

            Text(isCurrent && service.duration > 0 ? format(service.duration) : "–:––")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .leading)

            if isCurrent && service.isPreparing {
                Button("Cancel") { service.stop() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Cancel preview preparation")
            } else if isCurrent, case .failed(let message) = service.state {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(message)
                    .accessibilityLabel("Preview failed: \(message)")
            }

            Menu {
                Button("Skip intro") { service.skipIntro() }
                    .disabled(!isPlayable)
                Button("Back 10 seconds") { service.seek(by: -10) }
                    .disabled(!isPlayable)
                Button("Forward 10 seconds") { service.seek(by: 10) }
                    .disabled(!isPlayable)
                Divider()
                Button("Stop preview") { service.stop() }
                    .disabled(!isCurrent)
                if showsPositionOption {
                    Divider()
                    Toggle("Keep position when switching sources", isOn: $service.keepTimestampAcrossCandidates)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Preview options")
            .help("Preview options")
        }
        .font(.callout)
        .padding(.vertical, 4)
    }

    private func format(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.rounded(.down)))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}
