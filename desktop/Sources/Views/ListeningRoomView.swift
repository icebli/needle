import AppKit
import SwiftUI

struct ListeningRoomView: View {
    let candidates: [CandidateResult]
    let artist: String
    let title: String
    let album: String
    let bookmarks: BookmarkStore
    @ObservedObject var preview: AudioPreviewService
    let disabled: Bool
    let saveLabel: String
    var showsHeader = true
    let save: (CandidateResult) -> Void

    @State private var selectedID: String?
    @State private var showExcluded = false

    private var visibleCandidates: [CandidateResult] {
        candidates.filter { showExcluded || $0.score.status != "rejected" }
    }

    private var selected: CandidateResult? {
        visibleCandidates.first { $0.id == selectedID } ?? visibleCandidates.first
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if showsHeader { roomHeader }
                if candidates.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "music.note.list", description: Text("Search for a recording to compare sources here."))
                } else {
                    if candidates.contains(where: { $0.score.status == "rejected" }) {
                        Toggle("Show excluded recordings", isOn: $showExcluded)
                            .toggleStyle(.checkbox)
                            .font(.callout)
                    }
                    if let selected {
                        if geometry.size.width >= 720 {
                            HStack(alignment: .top, spacing: 22) {
                                sourceList.frame(width: max(280, (geometry.size.width - 78) * 0.43))
                                evidenceInspector(selected).frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 16) {
                                sourceList
                                evidenceInspector(selected)
                            }
                        }
                    } else {
                        ContentUnavailableView("All recordings are excluded", systemImage: "nosign", description: Text("Show excluded recordings to inspect why they were rejected."))
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            auditionRail
        }
        }
        .onAppear { reconcileSelection() }
        .onChange(of: candidates.map { [$0.id, $0.candidate.url] }) { _, _ in
            preview.stop()
            reconcileSelection()
        }
        .onChange(of: showExcluded) { _, _ in reconcileSelection() }
        .onChange(of: selectedID) { oldID, newID in
            guard oldID != newID else { return }
            preview.stop()
        }
    }

    private var roomHeader: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Listening Room", systemImage: "waveform.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Text(title.isEmpty ? "Untitled recording" : title)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .lineLimit(2)
                Text(album.isEmpty ? artist : "\(artist) · \(album)")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text("Choose the source you trust. Needle keeps the evidence visible until you approve it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if let selected { ListeningRoomArtwork(candidate: selected.candidate, size: 150) }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private var auditionRail: some View {
        if let selected {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    auditionIdentity(selected).frame(minWidth: 180)
                    PreviewControlsView(service: preview, candidate: selected, showsPositionOption: true)
                        .frame(minWidth: 280, maxWidth: 620)
                }
                VStack(alignment: .leading, spacing: 6) {
                    auditionIdentity(selected)
                    PreviewControlsView(service: preview, candidate: selected, showsPositionOption: true)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .background(.bar)
            .padding(.horizontal, 18)
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audition controls for \(selected.candidate.title)")
        }
    }

    private func auditionIdentity(_ result: CandidateResult) -> some View {
        HStack(spacing: 10) {
            ListeningRoomArtwork(candidate: result.candidate, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.isPlaying ? "Now auditioning" : "Audition")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(result.candidate.title).font(.callout.weight(.medium)).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Sources").font(.headline)
                Spacer()
                Text("\(visibleCandidates.count) to compare").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 7) {
                ForEach(visibleCandidates) { result in
                    ListeningRoomSourceRow(result: result, selected: result.id == selectedID) {
                        selectedID = result.id
                    }.disabled(disabled)
                }
            }
        }
    }

    private func evidenceInspector(_ result: CandidateResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ListeningRoomArtwork(candidate: result.candidate, size: 68)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Evidence inspector").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    Text(result.candidate.title).font(.headline).lineLimit(2)
                    Text(result.candidate.uploader ?? result.candidate.provider)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            statusBanner(result)
            CandidateMetadataView(candidate: result.candidate)
                .id(result.id + result.candidate.url)
            evidenceFacts(result)
            reasonSection(result)
            HStack(spacing: 10) {
                Button {
                    bookmarks.toggle(artist: artist, title: title, album: album,
                                     candidate: result.candidate, score: result.score)
                } label: {
                    Label(bookmarks.contains(candidate: result.candidate) ? "Bookmarked" : "Bookmark",
                          systemImage: bookmarks.contains(candidate: result.candidate) ? "bookmark.fill" : "bookmark")
                }
                .buttonStyle(.borderless)
                if let url = AppModel.mediaURL(result.candidate.url) {
                    Button("Open source") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless)
                }
            }
            Button(saveLabel) { save(result) }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .frame(maxWidth: .infinity)
                .disabled(disabled || result.score.status == "rejected" || AppModel.mediaURL(result.candidate.url) == nil)
                .help(result.score.status == "rejected" ? "Excluded sources cannot be approved." : "Review metadata before saving this source.")
        }
        .padding(18)
        .background(inspectorBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.quaternary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Evidence inspector for \(result.candidate.title)")
        .id([result.id, result.candidate.url])
    }

    private func statusBanner(_ result: CandidateResult) -> some View {
        let rejected = result.score.status == "rejected"
        let recommended = result.score.status == "recommended"
        return Label(
            rejected ? "Excluded from approval" : recommended ? "Recommended match" : "Review this version",
            systemImage: rejected ? "nosign" : recommended ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
        )
        .font(.callout.weight(.semibold))
        .foregroundStyle(rejected ? Color.secondary : recommended ? Color.green : Color.orange)
    }

    private func evidenceFacts(_ result: CandidateResult) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Source details").font(.subheadline.weight(.semibold))
            fact("Provider", result.candidate.provider.capitalized)
            fact("Uploader", result.candidate.uploader ?? "Unknown")
            fact("Duration", duration(result.candidate.durationMs))
            fact("Channel", channelStatus(result.candidate.channelIsVerified))
            fact("Codec", result.candidate.audioCodec ?? "Not reported")
            fact("Bitrate", result.candidate.audioBitrateKbps.map { "\($0) kbps" } ?? "Not reported")
            fact("Score", result.score.confidence.map { "\(Int($0)) · ranking signal only" } ?? "Unavailable · ranking signal only")
        }
    }

    private func reasonSection(_ result: CandidateResult) -> some View {
        let positives = result.score.positives
        let concerns = result.score.rejects + result.score.warnings
        return VStack(alignment: .leading, spacing: 7) {
            Text("Why this source").font(.subheadline.weight(.semibold))
            ForEach(Array(positives.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            }
            ForEach(Array(concerns.enumerated()), id: \.offset) { index, reason in
                let isReject = index < result.score.rejects.count
                Label(reason, systemImage: isReject ? "xmark.circle" : "exclamationmark.circle")
                    .foregroundStyle(isReject ? Color.secondary : Color.orange)
            }
            if positives.isEmpty && concerns.isEmpty {
                Text("No additional resolver explanation was returned.").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private var inspectorBackground: some ShapeStyle {
        AnyShapeStyle(Color(nsColor: .underPageBackgroundColor).opacity(0.92))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).lineLimit(2).textSelection(.enabled)
        }
    }

    private func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "Unknown" }
        return String(format: "%d:%02d", milliseconds / 60_000, milliseconds / 1_000 % 60)
    }

    private func channelStatus(_ verified: Bool?) -> String {
        switch verified {
        case true: return "Verified by provider"
        case false: return "Not verified"
        case nil: return "Not reported"
        }
    }

    private func reconcileSelection() {
        if let selectedID, visibleCandidates.contains(where: { $0.id == selectedID }) { return }
        selectedID = visibleCandidates.first?.id
    }
}

private struct ListeningRoomSourceRow: View {
    let result: CandidateResult
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                ListeningRoomArtwork(candidate: result.candidate, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.candidate.title).font(.callout.weight(.medium)).lineLimit(2)
                    HStack(spacing: 5) {
                        Text(result.candidate.provider.capitalized)
                        Text("·")
                        Text(duration).monospacedDigit()
                        if result.candidate.channelIsVerified == true { Image(systemName: "checkmark.seal.fill") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Label(result.score.status == "rejected" ? "Excluded" : result.score.status.capitalized,
                      systemImage: result.score.status == "rejected" ? "nosign" : "circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(result.score.status == "recommended" ? .green : .secondary)
            }
            .padding(9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(selected ? Color.orange.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(selected ? Color.orange.opacity(0.55) : Color.clear, lineWidth: 1)
        }
        .accessibilityLabel("\(result.candidate.title), \(result.candidate.provider)")
        .accessibilityValue(selected ? "Selected" : result.score.status)
    }

    private var duration: String {
        guard let milliseconds = result.candidate.durationMs else { return "unknown" }
        return String(format: "%d:%02d", milliseconds / 60_000, milliseconds / 1_000 % 60)
    }
}

private struct ListeningRoomArtwork: View {
    let candidate: Candidate
    let size: CGFloat

    var body: some View {
        AsyncImage(url: candidate.thumbnailURL.flatMap(AppModel.mediaURL)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default:
                ZStack {
                    Color(nsColor: .controlBackgroundColor)
                    VStack(spacing: 5) {
                        Text("N").font(.system(size: size * 0.34, weight: .bold, design: .serif))
                        Text("SOURCE").font(.system(size: max(7, size * 0.07), weight: .semibold, design: .rounded)).tracking(1.2)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size > 80 ? 16 : 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size > 80 ? 16 : 10).stroke(.white.opacity(0.16)))
        .accessibilityLabel("Source artwork for \(candidate.title)")
        .help("Artwork from the source upload. It does not verify the recording.")
    }
}
