import SwiftUI
import AppKit

struct AddMusicView: View {
    let model: AppModel
    @State private var artist = ""
    @State private var title = ""
    @State private var album = ""
    @State private var sourceURL = ""
    @State private var queueSpotify = true
    @State private var showComposer = false
    @State private var metadataReviewDraft: MetadataDraft?
    @State private var metadataReviewCandidate: CandidateResult?
    @State private var preparingMetadata = false
    @State private var metadataTask: Task<Void, Never>?
    @StateObject private var preview = AudioPreviewService()

    private var format: String { model.requestSnapshot?.settings.format ?? model.settings.value.format }
    private var spotifyEnabled: Bool { queueSpotify && format == "mp3" }

    var body: some View {
        VStack(spacing: 0) {
            if model.searchResults.isEmpty || showComposer {
                searchComposer
            } else if !model.searchResults.isEmpty {
                HStack {
                    Label("Listening Room", systemImage: "waveform.circle").font(.headline)
                    Spacer()
                    Toggle("Add to Spotify", isOn: $queueSpotify).toggleStyle(.checkbox)
                        .disabled(format != "mp3" || preparingMetadata)
                        .help("Add the saved MP3 to \(model.requestSnapshot?.settings.playlistName ?? "Needle")")
                    Button("Change request", systemImage: "magnifyingglass") { showComposer = true }
                        .disabled(preparingMetadata)
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }
            if !model.searchResults.isEmpty || model.isSearching { Divider() }
            if !model.searchResults.isEmpty {
                ListeningRoomView(candidates: model.searchResults,
                                  artist: model.requestSnapshot?.artist ?? artist,
                                  title: model.requestSnapshot?.title ?? title,
                                  album: model.requestSnapshot?.album ?? album,
                                  bookmarks: model.bookmarks, preview: preview,
                                  disabled: model.isSearching || model.isCheckingTools || preparingMetadata,
                                  saveLabel: preparingMetadata ? "Preparing metadata…" : "Review metadata",
                                  save: requestSave)
            } else if model.isSearching {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Finding your recording").font(.title2.weight(.semibold))
                    Text("Comparing sources for \(model.requestSnapshot?.title ?? title).")
                        .foregroundStyle(.secondary)
                    Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancelCurrentOperation() }
                        .disabled(model.isCancelling)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    ListeningRoomWelcome(model: model)
                        .frame(maxWidth: 900)
                        .padding(.horizontal, 36)
                        .padding(.bottom, 36)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .onChange(of: artist) { resetSearch() }
        .onChange(of: title) { resetSearch() }
        .onChange(of: album) { resetSearch() }
        .onChange(of: sourceURL) { resetSearch() }
        .onDisappear { preview.stop(); metadataTask?.cancel(); preparingMetadata = false }
        .sheet(isPresented: metadataReviewPresented) {
            if let metadataReviewDraft, let metadataReviewCandidate {
                MetadataReviewView(draft: metadataReviewDraft, candidate: metadataReviewCandidate,
                                   onCancel: dismissMetadataReview) { approvedDraft in
                    model.save(candidate: metadataReviewCandidate,
                              queueSpotify: spotifyEnabled,
                              approved: approvedDraft)
                    dismissMetadataReview()
                }
            }
        }
    }

    private var searchComposer: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Find a recording").font(.system(size: model.searchResults.isEmpty ? 32 : 22, weight: .semibold, design: .serif))
                    Spacer()
                    Button("Open review queue", systemImage: "list.bullet.rectangle") { model.destination = .reviewQueue }
                        .buttonStyle(.borderless)
                }
                HStack(alignment: .bottom, spacing: 12) {
                    field("Artist", placeholder: "Artist name", text: $artist)
                    field("Song", placeholder: "Song title", text: $title)
                    Button(action: search) {
                        Label(model.isSearching ? "Searching…" : "Find recordings", systemImage: "magnifyingglass")
                    }
                    .needlePrimaryAction().tint(.orange).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isSearching || model.isCheckingTools || artist.trimmingCharacters(in: .whitespaces).isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                DisclosureGroup("Album hint or exact source link") {
                    HStack(spacing: 12) {
                        field("Album hint", placeholder: "Optional album", text: $album)
                        field("Source link", placeholder: "https://…", text: $sourceURL)
                    }.padding(.top, 8)
                }.font(.callout)
                if !model.searchResults.isEmpty {
                    HStack {
                        Toggle("Add to \(model.requestSnapshot?.settings.playlistName ?? "Needle") in Spotify after saving", isOn: $queueSpotify)
                            .toggleStyle(.checkbox).disabled(format != "mp3" || preparingMetadata)
                        Spacer()
                        Button("Clear results", action: resetSearch).disabled(preparingMetadata)
                    }.font(.caption)
                    if format != "mp3" { Text("\(format.uppercased()) files save locally. Spotify delivery requires MP3.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(24)
            .needleGlassSurface(cornerRadius: 24)
            .frame(maxWidth: 900)
            .padding(model.searchResults.isEmpty && !model.isSearching ? 36 : 16)
            .frame(maxWidth: .infinity)
            .disabled(preparingMetadata)
    }

    private func search() { showComposer = false; preview.stop(); model.search(artist: artist, title: title, album: album, sourceURL: sourceURL) }
    private func resetSearch() { preview.stop(); model.clearSearch() }

    private var metadataReviewPresented: Binding<Bool> {
        Binding(
            get: { metadataReviewDraft != nil && metadataReviewCandidate != nil },
            set: { presented in
                if !presented { dismissMetadataReview() }
            }
        )
    }

    private func requestSave(for result: CandidateResult) {
        preview.stop()
        preparingMetadata = true
        let snapshot = model.requestSnapshot
        metadataTask = Task {
            let draft = await model.prepareMetadata(candidate: result, queueSpotify: spotifyEnabled)
            await MainActor.run {
                preparingMetadata = false
                guard !Task.isCancelled, model.requestSnapshot == snapshot, let draft else { return }
                metadataReviewCandidate = result
                metadataReviewDraft = draft
            }
        }
    }

    private func dismissMetadataReview() {
        metadataReviewDraft = nil
        metadataReviewCandidate = nil
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).controlSize(.large).disabled(model.isSearching)
                .onSubmit { search() }
        }
    }
}
