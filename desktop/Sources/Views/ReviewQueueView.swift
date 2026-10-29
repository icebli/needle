import SwiftUI

struct ReviewQueueView: View {
    let model: AppModel
    @State private var pasted = ""
    @State private var showImport = false
    @StateObject private var preview = AudioPreviewService()
    private var queue: ReviewQueue { model.reviewQueue }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Queue").font(.largeTitle.bold())
                    Text("Choose a recording before it is saved.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if queue.activeDownloads > 0 {
                    ProgressView().controlSize(.small)
                    Text("\(queue.activeDownloads) downloading").font(.callout)
                }
                Menu {
                    Toggle("Keep preview position", isOn: $preview.keepTimestampAcrossCandidates)
                    Button("Paste a list", systemImage: "text.badge.plus") { showImport = true }
                } label: {
                    Label("Queue actions", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                Button("Add recordings", systemImage: "plus") { showImport = true }
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
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title.isEmpty ? item.label : item.title)
                                        .lineLimit(1).font(.callout.weight(.medium))
                                    Text(queueSubtitle(for: item)).lineLimit(1).font(.caption)
                                        .foregroundStyle(queueStateColor(item.state))
                                }.padding(.vertical, 5).tag(item.id)
                            }
                        }.listStyle(.inset)
                        Button("Clear finished") { queue.removeFinished() }
                            .disabled(!queue.items.contains { [.saved, .skipped].contains($0.state) })
                    }.frame(minWidth: 190, idealWidth: 220, maxWidth: 240)
                    if let item = queue.selected {
                        ReviewItemView(item: item, queue: queue, bookmarks: model.bookmarks, preview: preview)
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

    private func queueStateColor(_ state: ReviewState) -> Color {
        state == .failed ? .orange : .secondary
    }

    private func queueSubtitle(for item: ReviewItem) -> String {
        item.artist.isEmpty ? item.state.label : "\(item.artist) · \(item.state.label)"
    }
}

private struct ReviewItemView: View {
    let item: ReviewItem
    let queue: ReviewQueue
    let bookmarks: BookmarkStore
    let preview: AudioPreviewService
    @State private var artist: String
    @State private var title: String
    @State private var source: String
    @State private var spotify = false
    @State private var showEdit = false
    @State private var reviewDraft: MetadataDraft?
    @State private var reviewCandidate: CandidateResult?
    @State private var preparingMetadata = false
    @State private var metadataTask: Task<Void, Never>?

    init(item: ReviewItem, queue: ReviewQueue, bookmarks: BookmarkStore, preview: AudioPreviewService) {
        self.item = item; self.queue = queue; self.bookmarks = bookmarks; self.preview = preview
        _artist = State(initialValue: item.artist)
        _title = State(initialValue: item.title)
        _source = State(initialValue: item.sourceURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.label).font(.title2.bold()).textSelection(.enabled)
                        Text(item.state.label).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if [.searching, .downloading].contains(item.state) {
                        Button("Cancel") { queue.cancel(item.id) }
                    } else if ![.approved, .saved].contains(item.state) {
                        Button("Skip") { preview.stop(); queue.skip(item.id) }.disabled(preparingMetadata)
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
                        Toggle("Add to Spotify playlist ‘\(item.settings.playlistName)’", isOn: $spotify)
                            .toggleStyle(.checkbox)
                            .disabled(item.settings.format != "mp3")
                            .help("Needle saves the local file either way. With the companion, it also adds the MP3 to this playlist.")
                        Spacer()
                        Menu {
                            Button("Edit request") { showEdit.toggle() }.disabled(preparingMetadata)
                        } label: {
                            Label("Review options", systemImage: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                    if item.settings.format != "mp3" {
                        Text("Spotify delivery requires MP3.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ListeningRoomView(candidates: response.candidates, artist: item.artist, title: item.title,
                                      album: response.metadata?.album ?? "", bookmarks: bookmarks, preview: preview,
                                      disabled: preparingMetadata,
                                      saveLabel: preparingMetadata ? "Preparing metadata…" : "Review metadata", showsHeader: false) { candidate in
                        preview.stop()
                        preparingMetadata = true
                        metadataTask = Task {
                            let draft = await queue.prepareMetadata(candidate, itemID: item.id)
                            preparingMetadata = false
                            guard !Task.isCancelled, queue.selectedID == item.id,
                                  queue.selected?.state == .ready else { return }
                            if let draft { reviewCandidate = candidate; reviewDraft = draft }
                        }
                    }
                }
                if item.state == .searching || item.state == .downloading {
                    ProgressView().controlSize(.small)
                }
        }.padding(.horizontal, 16).padding(.bottom, 12)
        .onDisappear { metadataTask?.cancel(); preparingMetadata = false }
        .onChange(of: item.artist) { artist = item.artist }
        .onChange(of: item.title) { title = item.title }
        .sheet(item: $reviewDraft) { draft in
            if let candidate = reviewCandidate {
                MetadataReviewView(draft: draft, candidate: candidate, onCancel: { reviewDraft = nil; reviewCandidate = nil }) { approved in
                    queue.approve(candidate, itemID: item.id, spotify: spotify, approved: approved)
                    reviewDraft = nil
                    reviewCandidate = nil
                }
            }
        }
    }

}
