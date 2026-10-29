import SwiftUI
import AppKit

struct LibraryView: View {
    let model: AppModel
    @State private var query = ""
    @State private var repairTrack: TrackRequest?
    private var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/needle") }
    private var tracks: [TrackRequest] {
        model.history.tracks.filter { track in
            guard let path = track.savedPath else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }

    private var matchingTracks: [TrackRequest] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty ? tracks : tracks.filter {
            "\($0.artist) \($0.title) \($0.album)".localizedStandardContains(term)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Library").font(.largeTitle.bold())
            Text("Recordings in your Needle folder, including files added outside the app.").foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Label("\(tracks.count) recordings", systemImage: "music.note.list")
                if model.libraryImportedCount > 0 {
                    Text("\(model.libraryImportedCount) newly found").foregroundStyle(.secondary)
                }
            }.font(.callout)
            HStack {
                Image(systemName: "folder.fill").foregroundStyle(.orange)
                Text(folder.path).font(.callout).textSelection(.enabled)
                Spacer()
                if model.isScanningLibrary { ProgressView().controlSize(.small) }
                Button("Refresh") { model.scanLibrary() }.disabled(model.isScanningLibrary)
                Button {
                    model.enqueueAllLibraryTracksToSpotify()
                } label: {
                    Label("Add all to Spotify", systemImage: "arrow.down.circle.fill")
                }
                .disabled(model.isScanningLibrary || tracks.isEmpty)
                .help("Queue every saved MP3 that is not already delivered or waiting")
                Button("Open folder") {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(folder)
                    } catch { model.message = error.localizedDescription }
                }
            }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            if let error = model.libraryScanError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if !model.libraryScanWarnings.isEmpty {
                Label("\(model.libraryScanWarnings.count) scan warning\(model.libraryScanWarnings.count == 1 ? "" : "s")", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(model.libraryScanWarnings.joined(separator: "\n"))
            }
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
                    List(matchingTracks) { track in HStack { LibraryArtwork(track: track, model: model); TrackRow(track: track, model: model); Button("Repair") { repairTrack = track }.buttonStyle(.bordered) } }.listStyle(.inset)
                }
            }
        }.padding(32)
            .task { model.scanLibrary() }
            .sheet(item: $repairTrack) { track in LibraryRepairView(model: model, track: track) }
    }
}

private struct LibraryArtwork: View {
    let track: TrackRequest
    let model: AppModel
    @State private var artworkPath: String?
    var body: some View {
        ArtworkThumbnail(path: artworkPath).frame(width: 44, height: 44)
            .accessibilityLabel("Embedded artwork for \(track.title)")
            .task(id: track.date) {
                artworkPath = nil
                if case .success(let inspection) = await LibraryRepairService().inspect(track, settings: model.settings.value) {
                    artworkPath = inspection.artwork.first?.extractedPath
                }
            }
    }
}
