import SwiftUI
import AppKit

struct LibraryRepairView: View {
    let model: AppModel; let track: TrackRequest
    @Environment(\.dismiss) private var dismiss
    @State private var inspection: LibraryRepairService.Inspection?
    @State private var suggestions: [LibraryRepairService.Suggestion] = []
    @State private var artist = ""; @State private var title = ""; @State private var album = ""
    @State private var clearAlbum = false; @State private var artworkURL: URL?; @State private var remoteArtworkURL: URL?; @State private var sourceArtworkCandidateURL: URL?
    @State private var isWorking = false; @State private var status: String?; @State private var warning: String?; @State private var backupPath: String?
    private let service = LibraryRepairService()
    var body: some View {
        NavigationStack {
            Form {
                Section("Current recording") {
                    if let inspection {
                        HStack(spacing: 14) { ArtworkThumbnail(path: inspection.artwork.first?.extractedPath); VStack(alignment: .leading) { Text(inspection.title ?? "Untitled").font(.headline); Text(inspection.artist ?? "Unknown artist").foregroundStyle(.secondary); Text(inspection.album ?? "No album").font(.caption).foregroundStyle(.secondary) } }
                    } else if isWorking { ProgressView("Reading embedded tags…") }
                }
                Section("Preview changes") {
                    TextField("Artist", text: $artist); TextField("Title", text: $title); TextField("Album", text: $album); Toggle("Remove album", isOn: $clearAlbum)
                    if let inspection { RepairDiffView(current: inspection, artist: artist, title: title, album: album, clearAlbum: clearAlbum) }
                }
                Section("Artwork and suggestions") {
                    if let warning { Label(warning, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
                    if let artworkURL { HStack { ArtworkThumbnail(path: artworkURL.path); Text(artworkURL.lastPathComponent); Spacer(); Button("Remove") { self.artworkURL = nil } } }
                    Button("Choose image…") { chooseArtwork() }
                    Button("Find metadata suggestions") { findSuggestions() }.disabled(inspection == nil || isWorking)
                    ForEach(suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 5) {
                            Text([suggestion.artist, suggestion.title].compactMap { $0 }.joined(separator: " — "))
                            Text(suggestion.album ?? "No album").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Use metadata") { artist = suggestion.artist ?? artist; title = suggestion.title ?? title; album = suggestion.album ?? album }
                                if let url = suggestion.artworkURL.flatMap(URL.init(string:)) { Button("Use artwork") { remoteArtworkURL = url; artworkURL = nil } }
                            }
                        }.padding(.vertical, 3)
                    }
                    Button("Find source artwork") { findSourceArtwork() }.disabled(isWorking || track.sourceURL.isEmpty)
                    if let sourceArtworkCandidateURL { HStack { AsyncImage(url: sourceArtworkCandidateURL) { $0.resizable().scaledToFill() } placeholder: { ProgressView() }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6)); Button("Use source artwork") { remoteArtworkURL = sourceArtworkCandidateURL; artworkURL = nil } } }
                    if let remoteArtworkURL { HStack { AsyncImage(url: remoteArtworkURL) { $0.resizable().scaledToFill() } placeholder: { ProgressView() }.frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 6)); Text("Suggested artwork selected"); Button("Clear") { self.remoteArtworkURL = nil } } }
                }
                if let backupPath { Section("Backup") { Text("A backup was created before applying these changes.").font(.caption); Button("Reveal backup") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backupPath)]) }; Button("Done") { dismiss() } } }
                if let status { Section { Text(status).font(.callout).foregroundStyle(.secondary) } }
            }.formStyle(.grouped).navigationTitle("Repair recording").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(backupPath == nil ? "Cancel" : "Close") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply changes") { apply() }.disabled(!hasChanges || isWorking) }
            }.task { await load() }
        }.frame(minWidth: 560, minHeight: 580)
    }
    private var hasChanges: Bool { guard let inspection else { return false }; return artist != (inspection.artist ?? "") || title != (inspection.title ?? "") || album != (inspection.album ?? "") || clearAlbum || artworkURL != nil || remoteArtworkURL != nil }
    private func load() async { guard inspection == nil else { return }; isWorking = true; defer { isWorking = false }; switch await service.inspect(track, settings: model.settings.value) { case .success(let value): inspection = value; artist = value.artist ?? track.artist; title = value.title ?? track.title; album = value.album ?? track.album; case .failure(let error): status = error.localizedDescription } }
    private func findSuggestions() { guard let inspection else { return }; isWorking = true; Task { defer { isWorking = false }; switch await service.suggestions(for: inspection, settings: model.settings.value) { case .success(let result): suggestions = result.0; warning = result.1; status = suggestions.isEmpty ? "No authoritative metadata suggestions were found." : "Preview metadata or artwork separately before applying."; case .failure(let error): status = error.localizedDescription } } }
    private func findSourceArtwork() { isWorking = true; Task { defer { isWorking = false }; switch await service.sourceArtwork(track, settings: model.settings.value) { case .success(let url): sourceArtworkCandidateURL = url; status = "Source artwork found. Preview it, then choose Use source artwork."; case .failure(let error): status = error.localizedDescription } } }
    private func chooseArtwork() { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.allowsMultipleSelection = false; if panel.runModal() == .OK { artworkURL = panel.url; remoteArtworkURL = nil } }
    private func apply() {
        guard let currentInspection = inspection else { return }
        guard !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Artist and title are required."; return
        }
        guard clearAlbum || !album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (currentInspection.album ?? "").isEmpty else {
            status = "To remove the album, turn on Remove album."; return
        }
        isWorking = true
        Task {
            defer { isWorking = false }
            switch await service.repair(track, artist: artist == (currentInspection.artist ?? "") ? nil : artist,
                                        title: title == (currentInspection.title ?? "") ? nil : title,
                                        album: album == (currentInspection.album ?? "") ? nil : album,
                                        clearAlbum: clearAlbum, artworkURL: artworkURL,
                                        remoteArtworkURL: remoteArtworkURL, settings: model.settings.value) {
            case .success(let result):
                let previous = model.history.tracks.first(where: { $0.id == track.id }) ?? track
                var updated = previous
                updated.artist = result.0.artist ?? artist
                updated.title = result.0.title ?? title
                updated.album = result.0.album ?? ""
                updated.date = .now
                model.history.upsert(updated)
                model.reconcileSpotifyMetadata(updated, previous: previous)
                backupPath = result.1
                status = "Saved changes to the existing audio file. Needle is checking its existing Spotify playlist entry automatically. Spotify artwork refresh remains unconfirmed."
                artworkURL = nil; remoteArtworkURL = nil; sourceArtworkCandidateURL = nil
                clearAlbum = false
                artist = updated.artist; title = updated.title; album = updated.album
                if case .success(let refreshed) = await service.inspect(updated, settings: model.settings.value) { inspection = refreshed }
                else { inspection = result.0 }
            case .failure(let error): status = error.localizedDescription
            }
        }
    }
}

struct ArtworkThumbnail: View { let path: String?; var body: some View { Group { if let path, let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary) } }.frame(width: 64, height: 64).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).clipShape(RoundedRectangle(cornerRadius: 8)) } }
private struct RepairDiffView: View {
    let current: LibraryRepairService.Inspection
    let artist: String
    let title: String
    let album: String
    let clearAlbum: Bool
    private func value(_ value: String?) -> String { value ?? "(empty)" }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Needle will update:").font(.caption.weight(.semibold))
            if artist != (current.artist ?? "") { Text("Artist: \(value(current.artist)) → \(artist)") }
            if title != (current.title ?? "") { Text("Title: \(value(current.title)) → \(title)") }
            if clearAlbum { Text("Album: \(value(current.album)) → (removed)") }
            else if album != (current.album ?? "") { Text("Album: \(value(current.album)) → \(album)") }
        }.font(.caption).foregroundStyle(.secondary)
    }
}
