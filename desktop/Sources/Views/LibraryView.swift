import SwiftUI
import AppKit

struct LibraryView: View {
    let model: AppModel
    @State private var query = ""
    private var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/needle") }
    private var tracks: [TrackRequest] { model.history.tracks.filter { $0.savedPath != nil } }

    private var matchingTracks: [TrackRequest] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? tracks : tracks.filter {
            "\($0.artist) \($0.title) \($0.album)".localizedStandardContains(term)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Library").font(.largeTitle.bold())
            Text("Recordings saved by Needle on this computer.").foregroundStyle(.secondary)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.orange)
                Text(folder.path).font(.callout).textSelection(.enabled)
                Spacer()
                Button("Open folder") {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    } catch { model.message = error.localizedDescription }
                }
            }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            if tracks.isEmpty {
                ContentUnavailableView("No saved recordings yet", systemImage: "music.note.list",
                                       description: Text("Your approved downloads will appear here."))
            } else {
                TextField("Filter by artist, song, or album", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Filter library")
                if matchingTracks.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(matchingTracks) { track in TrackRow(track: track, model: model) }.listStyle(.inset)
                }
            }
        }.padding(32)
    }
}
