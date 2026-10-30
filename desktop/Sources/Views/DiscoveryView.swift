import SwiftUI

struct DiscoveryView: View {
    let model: AppModel
    @State private var showCatalogMatches = false
    @State private var showArtists = false
    @State private var showSetup = false
    private var store: DiscoveryStore { model.discovery }
    private var busy: Bool { store.isSyncing || store.isSearching }
    private var selectedArtists: [SpotifyArtist] { store.artists.filter { store.selectedArtistIDs.contains($0.id) } }
    private var visible: [DiscoveryRecording] {
        store.recordings.filter { showCatalogMatches || $0.availability != .found }
    }
    private var artistSummary: String {
        let names = selectedArtists.prefix(2).map(\.name).joined(separator: ", ")
        return names.isEmpty ? "Choose artists" : names + (selectedArtists.count > 2 ? " +\(selectedArtists.count - 2)" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Discover").font(.largeTitle.bold())
                    Text("Find recordings beyond Spotify.").foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Sync top artists", systemImage: "arrow.triangle.2.circlepath") { store.sync() }.disabled(busy)
                    Button("Spotify setup…", systemImage: "slider.horizontal.3") { showSetup = true }
                } label: { Label("Spotify", systemImage: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            if let error = store.error {
                HStack(alignment: .top) {
                    Label(error, systemImage: "exclamationmark.triangle").textSelection(.enabled)
                    Spacer()
                    Button("Spotify setup") { showSetup = true }
                }.font(.callout).foregroundStyle(.orange)
            }
            if store.artists.isEmpty {
                ContentUnavailableView {
                    Label(store.isSyncing ? "Reading your top artists…" : "Start with your favorite artists", systemImage: "music.note.list")
                } description: {
                    Text("Connect through Spotify’s Needle companion, then choose who to explore.")
                } actions: {
                    Button("Sync top artists") { store.sync() }.disabled(busy)
                        .buttonStyle(.borderedProminent).tint(.orange)
                    Button("Set up Spotify") { showSetup = true }
                }
            } else {
                HStack(spacing: 12) {
                    Button { showArtists = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2")
                            Text(artistSummary).lineLimit(1)
                            Text("\(selectedArtists.count) selected").foregroundStyle(.secondary)
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }
                    .disabled(busy).popover(isPresented: $showArtists) { artistChooser }
                    .accessibilityLabel("Choose artists, \(selectedArtists.count) selected")
                    Spacer(minLength: 8)
                    Button("Refresh all", systemImage: "arrow.clockwise") { store.refreshCatalog() }
                        .disabled(store.recordings.isEmpty || busy)
                        .help("Recheck Spotify availability for all saved recordings.")
                    Button("Find recordings", systemImage: "magnifyingglass") {
                        store.find(settings: model.settings.value, library: model.history.tracks)
                    }.buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(selectedArtists.isEmpty || busy)
                }
                HStack(spacing: 14) {
                    Image(systemName: "sparkles.rectangle.stack")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Your listening room")
                            .font(.headline)
                        Text("Compare the source, listen briefly, then choose what belongs in your library.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(visible.count) to review")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                if store.isSearching || store.isSyncing {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(store.isSyncing ? "Syncing artists…" : store.progress).lineLimit(1)
                        Spacer()
                        Button("Stop") { store.cancel() }.buttonStyle(.borderless)
                    }.font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Recordings", selection: $showCatalogMatches) {
                        Text("To review (\(store.recordings.filter { $0.availability != .found }.count))").tag(false)
                        Text("All recordings (\(store.recordings.count))").tag(true)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                    Spacer()
                    if !store.recordings.isEmpty {
                        Text("Most played first").font(.caption).foregroundStyle(.secondary)
                            .help("Reported plays/views among these source results, not a complete ranking.")
                    }
                }
                if let notice = store.catalogNotice {
                    HStack {
                        Text(notice).lineLimit(2)
                        Spacer()
                        if notice.hasPrefix("Found on Spotify"), !showCatalogMatches {
                            Button("Show match") { showCatalogMatches = true }
                        }
                    }.font(.callout).foregroundStyle(.secondary)
                }
                if visible.isEmpty {
                    ContentUnavailableView(emptyTitle, systemImage: store.recordings.isEmpty ? "waveform" : "checkmark.circle",
                        description: Text(emptyDescription))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(visible) { recording in
                                DiscoveryRecordingRow(recording: recording, model: model, showSetup: { showSetup = true })
                                Divider()
                            }
                        }
                    }
                }
                if !store.warnings.isEmpty {
                    DisclosureGroup("Search notices (\(store.warnings.count))") {
                        ScrollView { Text(store.warnings.joined(separator: "\n")).font(.caption).textSelection(.enabled) }.frame(maxHeight: 90)
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showSetup) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spotify setup").font(.title2.bold())
                ScrollView { SetupView(model: model, expandedInitially: true) }
                HStack { Spacer(); Button("Done") { showSetup = false }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 600, height: 550)
        }
    }

    private var artistChooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose artists").font(.headline)
            HStack {
                Button("Select all") { store.selectedArtistIDs = Set(store.artists.map(\.id)) }
                Button("Clear") { store.selectedArtistIDs.removeAll() }
            }.disabled(busy)
            Text("Select any number of artists. Fewer artists gives each a deeper search.").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(store.artists.enumerated()), id: \.element.id) { index, artist in
                        Toggle(isOn: Binding(get: { store.selectedArtistIDs.contains(artist.id) }, set: { value in
                            if value { store.selectedArtistIDs.insert(artist.id) } else { store.selectedArtistIDs.remove(artist.id) }
                        })) { Text("\(index + 1). \(artist.name)") }
                        .toggleStyle(.checkbox)
                        .disabled(busy)
                        .help("Selected artists are searched in order, with paced Spotify checks.")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }.frame(height: 330)
            HStack {
                if let date = store.lastSynced { Text("Synced \(date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Done") { showArtists = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 340)
    }

    private var emptyTitle: String {
        if busy { return "Finding recordings…" }
        if store.error != nil { return "Search needs attention" }
        if !store.recordings.isEmpty { return "These recordings are already on Spotify" }
        return store.hasSearched ? "Nothing new found" : "Explore your artists"
    }
    private var emptyDescription: String {
        if busy { return "Results appear here as each recording is checked." }
        if store.error != nil { return "Check the message above, then try again." }
        if !store.recordings.isEmpty { return "View All recordings to open a Spotify match, or try another artist." }
        if store.hasSearched { return "Try another artist or source. Recordings already in your Library are skipped." }
        return "Choose artists and find recordings. Preview anything you like before saving."
    }
}

private struct DiscoveryRecordingRow: View {
    let recording: DiscoveryRecording
    let model: AppModel
    let showSetup: () -> Void
    @State private var showDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: 18) {
            AsyncImage(url: recording.candidate.thumbnailURL.flatMap { AppModel.mediaURL($0) }) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    LinearGradient(colors: [.orange.opacity(0.8), .brown.opacity(0.72), .indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").font(.title).foregroundStyle(.white.opacity(0.9))
                }
            }
            .frame(width: 104, height: 104).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .accessibilityLabel("Source artwork for \(recording.title)")
            VStack(alignment: .leading, spacing: 7) {
                Text(recording.title)
                    .font(.system(.title3, design: .serif).weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Text("\(recording.artist.name) · \(recording.candidate.provider.capitalized) · \(recording.candidate.uploader ?? "Unknown uploader")\(duration)")
                    .font(.callout).foregroundStyle(.secondary)
                CandidateMetadataView(candidate: recording.candidate)
                HStack(spacing: 8) {
                    Label(recording.availability.label, systemImage: recording.availability == .found ? "checkmark.circle" : recording.availability == .unknown ? "exclamationmark.circle" : "magnifyingglass")
                    Text("Source evidence")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(recording.availability == .unknown ? .orange : .secondary)
                if recording.availability == .unknown {
                    Text("The check failed; this does not mean the song is absent.").font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button {
                        model.bookmarks.toggle(artist: recording.artist.name, title: recording.title, candidate: recording.candidate)
                    } label: {
                        Label(model.bookmarks.contains(candidate: recording.candidate) ? "Bookmarked" : "Bookmark", systemImage: model.bookmarks.contains(candidate: recording.candidate) ? "bookmark.fill" : "bookmark")
                    }.buttonStyle(.borderless)
                    if recording.availability == .unknown {
                        Button("Retry check") { model.discovery.retryCatalog(recording) }
                            .disabled(model.discovery.isSearching || model.discovery.isSyncing)
                    }
                    Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }.buttonStyle(.borderless)
                    Spacer()
                    Menu {
                        if let url = AppModel.mediaURL(recording.candidate.url) { Link("Open source", destination: url) }
                        if let uri = recording.catalogURI, uri.hasPrefix("spotify:track:"), let url = URL(string: uri) {
                            Link("Open in Spotify", destination: url)
                        }
                        if recording.availability != .found {
                            Button("Check Spotify again") { model.discovery.retryCatalog(recording) }
                                .disabled(model.discovery.isSearching || model.discovery.isSyncing)
                        }
                        Button("Spotify setup…", action: showSetup)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).fixedSize()
                    Button("Preview & review", systemImage: "play.circle") {
                        model.reviewQueue.addDiscovery(recording, settings: model.settings.value)
                        model.destination = .reviewQueue
                    }.buttonStyle(.bordered)
                }.font(.callout)
                if showDetails {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Uploaded by \(recording.candidate.uploader ?? "Unknown uploader")")
                        if let detail = recording.detail { Text(detail) }
                        if recording.availability == .noMatch { Text("No exact match is a lead to review, not proof of worldwide unavailability.") }
                    }.font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.vertical, 8)
    }

    private var duration: String {
        guard let milliseconds = recording.candidate.durationMs else { return "" }
        let seconds = milliseconds / 1000
        return " · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}
