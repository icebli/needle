import SwiftUI

struct ReviewQueueView: View {
    let model: AppModel
    @State private var pasted = ""
    @State private var showImport = false
    @StateObject private var preview = AudioPreviewService()
    private var queue: ReviewQueue { model.reviewQueue }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Queue").font(.largeTitle.bold())
                    Text("Approve each recording. Downloads keep going while you review.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if queue.activeDownloads > 0 {
                    ProgressView().controlSize(.small)
                    Text("\(queue.activeDownloads) downloading").font(.callout)
                }
                Button("Paste a list", systemImage: "text.badge.plus") { showImport = true }
                    .buttonStyle(.borderedProminent).tint(.orange)
            }
            if queue.items.isEmpty {
                ContentUnavailableView {
                    Label("Bring your missing music", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Paste source links or one Artist — Title per line. You choose every recording before it downloads.")
                } actions: {
                    Button("Add recordings") { showImport = true }
                }
            } else {
                HSplitView {
                    VStack(alignment: .leading, spacing: 8) {
                        List(selection: Binding(get: { queue.selectedID }, set: { queue.selectedID = $0 })) {
                            ForEach(queue.items) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.label).lineLimit(2).font(.callout.weight(.medium))
                                    Text(item.state.label).font(.caption).foregroundStyle(item.state == .failed ? .orange : .secondary)
                                }.padding(.vertical, 5).tag(item.id)
                            }
                        }.listStyle(.inset)
                        Button("Clear finished") { queue.removeFinished() }
                            .disabled(!queue.items.contains { [.saved, .skipped].contains($0.state) })
                    }.frame(minWidth: 190, idealWidth: 220, maxWidth: 240)
                    if let item = queue.selected {
                        ReviewItemView(item: item, queue: queue, preview: preview)
                            .id(item.id).frame(minWidth: 430, maxWidth: .infinity)
                    } else {
                        ContentUnavailableView("Choose a recording", systemImage: "music.note")
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(24)
        .sheet(isPresented: $showImport) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add recordings to review").font(.title2.bold())
                Text("Paste one source link or Artist — Title per line (up to 100 at a time). Link details are suggestions for you to check.")
                    .foregroundStyle(.secondary)
                TextEditor(text: $pasted).font(.body.monospaced())
                    .frame(minHeight: 220).padding(6)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .accessibilityLabel("Recordings to add")
                HStack {
                    Button("Paste from clipboard") { pasted = NSPasteboard.general.string(forType: .string) ?? pasted }
                    Spacer()
                    Button("Cancel") { showImport = false }
                    Button("Add to queue") {
                        queue.add(pasted, settings: model.settings.value)
                        pasted = ""; showImport = false
                    }.buttonStyle(.borderedProminent).tint(.orange)
                        .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 620, height: 400)
        }
        .onChange(of: queue.selectedID) { preview.stop() }
        .onDisappear { preview.stop() }
        .task { queue.searchNext() }
    }
}

private struct ReviewItemView: View {
    let item: ReviewItem
    let queue: ReviewQueue
    let preview: AudioPreviewService
    @State private var artist: String
    @State private var title: String
    @State private var source: String
    @State private var spotify = false
    @State private var showEdit = false
    @State private var showExcluded = false

    init(item: ReviewItem, queue: ReviewQueue, preview: AudioPreviewService) {
        self.item = item; self.queue = queue; self.preview = preview
        _artist = State(initialValue: item.artist)
        _title = State(initialValue: item.title)
        _source = State(initialValue: item.sourceURL)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.label).font(.title2.bold()).textSelection(.enabled)
                        Text(item.state.label).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if [.searching, .downloading].contains(item.state) {
                        Button("Cancel") { queue.cancel(item.id) }
                    } else if ![.approved, .saved].contains(item.state) {
                        Button("Skip") { preview.stop(); queue.skip(item.id) }
                    }
                }
                if let detail = item.detail {
                    Text(detail).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if [.needsInput, .failed, .interrupted, .skipped].contains(item.state) || showEdit {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Artist", text: $artist).accessibilityLabel("Queue artist")
                        TextField("Song title", text: $title).accessibilityLabel("Queue song title")
                        TextField("Source link (optional)", text: $source).accessibilityLabel("Queue source link")
                        Button("Find recordings") {
                            preview.stop(); queue.edit(id: item.id, artist: artist, title: title, source: source); showEdit = false
                        }.disabled(artist.trimmingCharacters(in: .whitespaces).isEmpty || title.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.textFieldStyle(.roundedBorder)
                }
                if item.state == .ready, let response = item.response {
                    HStack {
                        Toggle("Add to \(item.settings.playlistName) in Spotify after saving", isOn: $spotify)
                            .toggleStyle(.checkbox).disabled(item.settings.format != "mp3")
                        Spacer()
                        Button("Edit request") { showEdit.toggle() }
                    }
                    Text("Playlist delivery requires the Spotify companion. The local file is saved either way.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Show excluded recordings", isOn: $showExcluded).toggleStyle(.checkbox)
                    ForEach(response.candidates.filter { showExcluded || $0.score.status != "rejected" }) { candidate in
                        CandidateCard(result: candidate, disabled: false, preview: preview, saveLabel: "Approve & download") {
                            preview.stop(); queue.approve(candidate, itemID: item.id, spotify: spotify)
                        }
                    }
                    if response.candidates.allSatisfy({ $0.score.status == "rejected" }) && !showExcluded {
                        Text("All sources were excluded. Show excluded recordings for the reasons, or edit the request.")
                    }
                }
                if item.state == .searching || item.state == .downloading {
                    ProgressView().controlSize(.small)
                }
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }
        .onChange(of: item.artist) { artist = item.artist }
        .onChange(of: item.title) { title = item.title }
    }
}
