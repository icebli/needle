import SwiftUI
import AppKit

struct AddMusicView: View {
    let model: AppModel
    @State private var artist = ""
    @State private var title = ""
    @State private var album = ""
    @State private var sourceURL = ""
    @State private var queueSpotify = true
    @State private var showExcluded = true
    @StateObject private var preview = AudioPreviewService()

    private var format: String { model.requestSnapshot?.settings.format ?? model.settings.value.format }
    private var spotifyEnabled: Bool { queueSpotify && format == "mp3" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SetupView(model: model)
                HStack {
                    Label("Have a list of recordings?", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Button("Open review queue") { model.destination = .reviewQueue }
                }.font(.callout)

                VStack(alignment: .leading, spacing: 16) {
                    Label("Find a recording", systemImage: "1.circle.fill").font(.headline)
                    HStack(spacing: 14) {
                        field("Artist", placeholder: "Artist name", text: $artist)
                        field("Song", placeholder: "Song title", text: $title)
                    }
                    DisclosureGroup("Album hint & source link") {
                        HStack(spacing: 14) {
                            field("Album hint", placeholder: "Optional album", text: $album)
                            field("Source link", placeholder: "Optional http or https link", text: $sourceURL)
                        }.padding(.top, 8)
                    }.font(.callout)
                    HStack {
                        Button(action: search) {
                            Label(model.isSearching ? "Finding recordings…" : "Find recordings", systemImage: "magnifyingglass")
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.isSearching || model.isCheckingTools || artist.trimmingCharacters(in: .whitespaces).isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                        if model.isSearching { ProgressView().controlSize(.small) }
                        if model.isSearching {
                            Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancelCurrentOperation() }
                                .disabled(model.isCancelling)
                        }
                        Spacer()
                        if !model.searchResults.isEmpty {
                            Button("Clear results") { resetSearch() }.disabled(model.isSearching)
                        }
                    }
                }
                .padding(22).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                if !model.searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Review the recording", systemImage: "2.circle.fill").font(.headline)
                            Spacer()
                            Text("\(model.searchResults.count) sources").font(.callout).foregroundStyle(.secondary)
                        }
                        if model.searchResults.contains(where: { $0.score.status == "rejected" }) {
                            Toggle("Show excluded recordings", isOn: $showExcluded).toggleStyle(.checkbox)
                        }
                        Text("Requested: \(model.requestSnapshot?.artist ?? artist) — \(model.requestSnapshot?.title ?? title)")
                            .foregroundStyle(.secondary)
                        Toggle("Add to \(model.requestSnapshot?.settings.playlistName ?? "Needle") in Spotify after saving", isOn: $queueSpotify)
                            .toggleStyle(.checkbox).disabled(format != "mp3" || model.isSearching)
                        if format != "mp3" {
                            Text("Advanced \(format.uppercased()) output: saved locally. Automatic Spotify delivery is available for MP3.")
                                .font(.callout).foregroundStyle(.secondary)
                        } else {
                            Text("Spotify must be open with Local Files enabled. Needle keeps the file even if Spotify needs more time.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.searchResults.filter { showExcluded || $0.score.status != "rejected" }) { result in
                        CandidateCard(result: result, disabled: model.isSearching || model.isCheckingTools, preview: preview,
                                      saveLabel: spotifyEnabled ? "Save & add to Spotify" : "Save recording") {
                            preview.stop()
                            model.save(candidate: result, queueSpotify: spotifyEnabled)
                        }
                    }
                } else if !model.isSearching {
                    HStack(spacing: 16) {
                        Image(systemName: "checkmark.shield").font(.title).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("You choose the source. Needle handles the rest.").font(.headline)
                            Text("Wrong versions stay visible. Your existing music stays safe.").foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                }
            }
            .padding(32).frame(maxWidth: 1080, alignment: .leading)
        }
        .onChange(of: artist) { resetSearch() }
        .onChange(of: title) { resetSearch() }
        .onChange(of: album) { resetSearch() }
        .onChange(of: sourceURL) { resetSearch() }
        .onDisappear { preview.stop() }
    }

    private func search() { preview.stop(); model.search(artist: artist, title: title, album: album, sourceURL: sourceURL) }
    private func resetSearch() { preview.stop(); model.clearSearch() }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).disabled(model.isSearching)
                .onSubmit { search() }
        }
    }
}

struct CandidateCard: View {
    let result: CandidateResult
    let disabled: Bool
    let preview: AudioPreviewService
    let saveLabel: String
    var showsPreviewPositionOption = true
    let save: () -> Void
    private var rejected: Bool { result.score.status == "rejected" }
    private var source: URL? { AppModel.mediaURL(result.candidate.url) }
    private var duration: String {
        guard let ms = result.candidate.durationMs else { return "Duration unavailable" }
        return "\(ms / 60_000):\(String(format: "%02d", (ms / 1000) % 60))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                artwork
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.candidate.title).font(.headline).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(result.candidate.uploader ?? result.candidate.provider).foregroundStyle(.secondary)
                    Text("\(result.candidate.provider.capitalized) · \(duration)").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            CandidateMetadataView(candidate: result.candidate)
            Label(rejected ? "Excluded recording" : result.score.status == "recommended" ? "Recommended match" : "Please check this version",
                  systemImage: rejected ? "nosign" : result.score.status == "recommended" ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.caption.weight(.semibold)).foregroundStyle(rejected ? Color.secondary : Color.orange)
            PreviewControlsView(service: preview, candidate: result,
                                showsPositionOption: showsPreviewPositionOption)
            ForEach(Array(uniqueReasons.enumerated()), id: \.offset) { _, reason in
                Label(reason, systemImage: rejected ? "xmark.circle" : "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("Open source") { if let source { NSWorkspace.shared.open(source) } }
                    .disabled(source == nil)
                    .buttonStyle(.borderless)
                Menu {
                    ForEach(Array(result.score.positives.enumerated()), id: \.offset) { _, reason in
                        Text(reason)
                    }
                    Text("Resolver score: \(Int(result.score.confidence ?? 0)) · ranking signal only")
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer(minLength: 8)
                Button(saveLabel, action: save).buttonStyle(.borderedProminent).tint(.orange)
                    .fixedSize().disabled(rejected || disabled || source == nil)
            }
        }
        .padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var uniqueReasons: [String] {
        var seen = Set<String>()
        return (rejected ? result.score.rejects : result.score.warnings).filter { seen.insert($0).inserted }
    }

    private var artwork: some View {
        AsyncImage(url: result.candidate.thumbnailURL.flatMap { AppModel.mediaURL($0) }) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .empty:
                artworkFallback.overlay {
                    if result.candidate.thumbnailURL != nil { ProgressView().controlSize(.small) }
                }
            case .failure:
                artworkFallback.overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            @unknown default:
                artworkFallback
            }
        }
        .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("Source artwork for \(result.candidate.title)")
        .help("Artwork from the source upload; it does not verify the recording.")
    }

    private var artworkFallback: some View {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
    }
}
