import SwiftUI

struct DiscoveryView: View {
    let model: AppModel
    @State private var showCatalogMatches = false
    private var store: DiscoveryStore { model.discovery }
    private var visible: [DiscoveryRecording] {
        store.recordings.filter { showCatalogMatches || $0.availability != .found }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Discover").font(.largeTitle.bold())
                    Text("Explore recordings from your favorite artists beyond Spotify’s catalog.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(store.isSyncing ? "Syncing…" : "Sync top artists", systemImage: "arrow.triangle.2.circlepath") { store.sync() }
                    .disabled(store.isSyncing || store.isSearching)
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            Text("Requires Spotify and Needle’s Spicetify companion. Sync reads your top 20 artists over roughly six months; your credentials stay in Spotify.")
                .font(.callout).foregroundStyle(.secondary)
            SetupView(model: model)
            if let error = store.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled) }
            if store.artists.isEmpty {
                ContentUnavailableView("Start with your top artists", systemImage: "sparkles",
                    description: Text("Open Spotify, enable Needle’s companion in setup, then sync. Needle never downloads discovery results until you approve them."))
            } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your top artists").font(.headline)
                        Text("Choose up to five per search.").font(.caption).foregroundStyle(.secondary)
                        List(Array(store.artists.enumerated()), id: \.element.id) { index, artist in
                            Toggle(isOn: Binding(get: { store.selectedArtistIDs.contains(artist.id) }, set: { value in
                                if value { store.selectedArtistIDs.insert(artist.id) } else { store.selectedArtistIDs.remove(artist.id) }
                            })) { Text("\(index + 1). \(artist.name)").lineLimit(2) }
                            .toggleStyle(.checkbox)
                            .disabled(store.isSearching || (!store.selectedArtistIDs.contains(artist.id) && store.selectedArtistIDs.count >= 5))
                        }.listStyle(.inset)
                        Button("Find recordings", systemImage: "magnifyingglass") { store.find(settings: model.settings.value, library: model.history.tracks) }
                            .disabled(store.selectedArtistIDs.isEmpty || store.isSearching || store.isSyncing)
                        if let date = store.lastSynced { Text("Synced \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary) }
                    }.frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isSearching {
                            HStack { ProgressView().controlSize(.small); Text(store.progress).lineLimit(2); Spacer(); Button("Stop") { store.cancel() } }
                        }
                        Toggle("Show recordings found on Spotify", isOn: $showCatalogMatches).toggleStyle(.checkbox)
                        Text("Ranked by reported source plays/views among these search results. No exact catalog match is a lead to review, not proof a song is unavailable everywhere.")
                            .font(.caption).foregroundStyle(.secondary)
                        if visible.isEmpty && !store.isSearching {
                            ContentUnavailableView("Explore another artist", systemImage: "waveform", description: Text("Select artists and find recordings. Existing Library recordings and exact Spotify matches are hidden."))
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(visible) { recording in DiscoveryRecordingRow(recording: recording, model: model) }
                                }
                            }
                        }
                        if !store.warnings.isEmpty {
                            DisclosureGroup("\(store.warnings.count) search notices") {
                                ScrollView { Text(store.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 100)
                            }
                        }
                    }.frame(minWidth: 420).padding(.leading, 12)
                }
            }
        }.padding(24)
    }
}

private struct DiscoveryRecordingRow: View {
    let recording: DiscoveryRecording
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(recording.title).font(.headline).textSelection(.enabled)
            Text("\(recording.artist.name) · \(recording.candidate.provider) · \(recording.candidate.uploader ?? "Unknown uploader")")
                .font(.callout).foregroundStyle(.secondary)
            Label(recording.availability.label, systemImage: recording.availability == .found ? "checkmark.circle" : "questionmark.circle")
                .font(.caption).foregroundStyle(recording.availability == .unknown ? .orange : .secondary)
            CandidateMetadataView(candidate: recording.candidate)
            if let detail = recording.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Link("Open source", destination: URL(string: recording.candidate.url)!)
                Spacer()
                Button("Preview & review", systemImage: "play.circle") {
                    model.reviewQueue.addDiscovery(recording, settings: model.settings.value)
                    model.destination = .reviewQueue
                }.buttonStyle(.bordered)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}
