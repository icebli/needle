import AppKit
import SwiftUI

struct ListeningRoomView: View {
    let candidates: [CandidateResult]
    let artist: String
    let title: String
    let album: String
    var artwork: ArtworkReference? = nil
    var settings = NeedleSettings()
    let bookmarks: BookmarkStore
    @ObservedObject var preview: AudioPreviewService
    let disabled: Bool
    let saveLabel: String
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
            HStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if let selected {
                            recordingHeader(selected, width: geometry.size.width - inspectorWidth)
                        }
                        sourceList
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                if let selected {
                    evidenceInspector(selected)
                        .frame(width: inspectorWidth)
                } else {
                    ContentUnavailableView("No source selected", systemImage: "music.note")
                        .frame(width: inspectorWidth)
                }
            }
        }
        .frame(minWidth: 740)
        .safeAreaInset(edge: .bottom, spacing: 0) { auditionRail }
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

    private let inspectorWidth: CGFloat = 270

    private func recordingHeader(_ result: CandidateResult, width: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 22) {
            Group {
                if let artwork {
                    AlbumArtworkView(artwork: artwork) {
                        ListeningRoomArtwork(candidate: result.candidate, size: min(260, max(170, width * 0.38)))
                    }
                    .frame(width: min(260, max(170, width * 0.38)), height: min(260, max(170, width * 0.38)))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                } else {
                    ListeningRoomArtwork(candidate: result.candidate, size: min(260, max(170, width * 0.38)))
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title.isEmpty ? "Untitled recording" : title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text(artist).font(.title3).foregroundStyle(.secondary).lineLimit(2)
                Divider().padding(.vertical, 4)
                if !album.isEmpty { headerFact("Album", album) }
                headerFact("Source", result.candidate.provider.capitalized)
                headerFact("Duration", duration(result.candidate.durationMs))
                headerFact("Uploader", result.candidate.uploader ?? "Unknown")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headerFact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout).lineLimit(2)
        }
    }

    @ViewBuilder private var auditionRail: some View {
        if let selected {
            HStack(spacing: 20) {
                HStack(spacing: 10) {
                    ListeningRoomArtwork(candidate: selected.candidate, size: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.candidate.title).font(.callout.weight(.medium)).lineLimit(1)
                        Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(width: 200, alignment: .leading)
                PreviewControlsView(service: preview, candidate: selected, showsPositionOption: true, settings: settings)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 22)
            .frame(height: 70)
            .needleGlassSurface(cornerRadius: 0)
            .overlay(alignment: .top) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Audition controls for \(selected.candidate.title)")
        }
    }

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Matching recordings").font(.headline)
                Text("\(visibleCandidates.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if candidates.contains(where: { $0.score.status == "rejected" }) {
                    Toggle("Show excluded", isOn: $showExcluded).toggleStyle(.checkbox).font(.caption)
                }
            }
            .padding(.bottom, 6)
            if visibleCandidates.isEmpty {
                ContentUnavailableView("No matching recordings", systemImage: "music.note.list",
                                       description: Text(showExcluded ? "No sources were returned." : "Show excluded sources to inspect their evidence."))
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(visibleCandidates) { result in
                        ListeningRoomSourceRow(result: result, selected: result.id == selected?.id) {
                            selectedID = result.id
                        }.disabled(disabled)
                    }
                }
            }
        }
    }

    private func evidenceInspector(_ result: CandidateResult) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Source inspector").font(.headline)
                    ListeningRoomArtwork(candidate: result.candidate, size: 222)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.candidate.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                        Text(result.candidate.uploader ?? result.candidate.provider)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    statusBanner(result)
                    CandidateMetadataView(candidate: result.candidate)
                        .id(result.id + result.candidate.url)
                    Divider()
                    evidenceFacts(result)
                    Divider()
                    reasonSection(result)
                    if let url = AppModel.mediaURL(result.candidate.url) {
                        Button("Open source", systemImage: "arrow.up.right") { NSWorkspace.shared.open(url) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            VStack(spacing: 10) {
                Button { save(result) } label: {
                    Text(saveLabel).frame(maxWidth: .infinity)
                }
                .needlePrimaryAction().tint(.orange).controlSize(.large)
                .disabled(disabled || result.score.status == "rejected" || AppModel.mediaURL(result.candidate.url) == nil)
                .help(result.score.status == "rejected" ? "Excluded sources cannot be approved." : "Review metadata before saving this source.")
                Button {
                    bookmarks.toggle(artist: artist, title: title, album: album,
                                     candidate: result.candidate, score: result.score, artwork: artwork)
                } label: {
                    Label(bookmarks.contains(candidate: result.candidate) ? "Bookmarked" : "Save to bookmarks",
                          systemImage: bookmarks.contains(candidate: result.candidate) ? "bookmark.fill" : "bookmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
            .padding(18)
        }
        .background(.regularMaterial)
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
        }.font(.caption)
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

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            Text(value).lineLimit(3).textSelection(.enabled)
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
                ListeningRoomArtwork(candidate: result.candidate, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.candidate.title).font(.callout.weight(.medium)).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(result.candidate.provider.capitalized)
                        Text("·")
                        Text(result.candidate.uploader ?? "Unknown uploader").lineLimit(1)
                        if result.candidate.channelIsVerified == true { Image(systemName: "checkmark.seal.fill") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Text(duration).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                Label(result.score.status == "rejected" ? "Excluded" : result.score.status.capitalized,
                      systemImage: result.score.status == "rejected" ? "nosign" : "circle.fill")
                    .font(.caption2.weight(.medium))
                    .frame(width: 82, alignment: .leading)
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
