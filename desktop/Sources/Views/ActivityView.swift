import SwiftUI
import AppKit

struct ActivityView: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Activity").font(.largeTitle.bold())
                    Text("File saving and Spotify delivery, tracked separately.").foregroundStyle(.secondary)
                }
                Spacer()
                if model.isBusy {
                    ProgressView().controlSize(.small)
                    Button(model.isCancelling ? "Cancelling…" : "Cancel") { model.cancelCurrentOperation() }
                        .disabled(model.isCancelling)
                }
            }
            let activityTracks = model.history.tracks.filter { $0.discoveredFromFolder != true }
            if activityTracks.isEmpty {
                ContentUnavailableView("Your collection starts here", systemImage: "tray",
                                       description: Text("Find and approve a recording in Add Music."))
            } else {
                List(activityTracks) { track in TrackRow(track: track, model: model) }.listStyle(.inset)
            }
        }.padding(32)
    }
}

private struct ActivityArtwork: View {
    let track: TrackRequest
    let model: AppModel
    let fallbackSymbol: String
    @State private var artworkPath: String?

    var body: some View {
        Group {
            if let artworkPath, let image = NSImage(contentsOfFile: artworkPath) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.title2)
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: 34, height: 34)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityLabel(artworkPath == nil ? "No embedded artwork" : "Embedded artwork for \(track.title)")
        .task(id: track.savedPath) {
            artworkPath = nil
            guard track.savedPath != nil else { return }
            let result = await LibraryRepairService().inspect(track, settings: model.settings.value)
            guard !Task.isCancelled else { return }
            if case .success(let inspection) = result {
                artworkPath = inspection.artwork.first?.extractedPath
            }
        }
    }
}

struct TrackRow: View {
    let track: TrackRequest
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                ActivityArtwork(track: track, model: model,
                               fallbackSymbol: track.savedPath == nil ? "waveform" : "music.note")
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.headline)
                    Text(track.artist + (track.album.isEmpty ? "" : " · \(track.album)")).foregroundStyle(.secondary)
                    Label(activityLabel(for: track), systemImage: activitySymbol(for: track))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(track.spotifyStatus == .failed ? .red : .primary)
                    if let path = track.savedPath {
                        DisclosureGroup("File details") {
                            Label(path, systemImage: "folder")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(.top, 2)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let path = track.savedPath {
                    VStack(alignment: .trailing, spacing: 8) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        if track.spotifyStatus != .added && (track.settingsSnapshot?.format ?? "mp3") == "mp3" {
                            Button(track.spotifyJobID == nil ? "Add to Spotify" : "Check Spotify") { model.enqueue(track) }
                                .disabled(model.pollingJobIDs.contains(track.id))
                        }
                    }
                }
            }
            if track.spotifyStatus == .added {
                HStack(spacing: 8) {
                    Label("Saved locally and added to \"\(track.spotifyPlaylistName ?? "Needle")\"", systemImage: "checkmark.circle.fill")
                    if track.spotifyPlaylistURI != nil {
                        Button("Open playlist") { model.openSpotifyPlaylist(track) }
                    }
                }
                .font(.caption).foregroundStyle(.green)
                DisclosureGroup("Details") {
                    Text("Spotify confirmed the playlist insertion. Playback has not been independently verified.")
                        .font(.caption).textSelection(.enabled)
                }.font(.caption)
            }
            if let detail = track.errorDetail {
                if track.spotifyStatus == .pending {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                } else {
                    DisclosureGroup("Details") { Text(detail).font(.caption).textSelection(.enabled) }.font(.caption)
                }
            }
        }.padding(.vertical, 12)
    }

    private func activityLabel(for track: TrackRequest) -> String {
        if track.spotifyStatus == .pending, track.spotifyReconcileNeeded == true { return "File saved · Updating Spotify metadata" }
        if track.spotifyStatus == .pending,
           track.errorDetail?.hasPrefix("Open Spotify Local Files and choose the recording:") == true {
            return "File saved · Spotify needs a recording choice"
        }
        guard track.spotifyStatus == .pending,
              let playlist = track.spotifyPlaylistName,
              track.savedPath != nil else { return track.stage.label }
        return "File saved · Waiting for Spotify to add to \"\(playlist)\""
    }

    private func activitySymbol(for track: TrackRequest) -> String {
        if track.spotifyStatus == .pending,
           track.errorDetail?.hasPrefix("Open Spotify Local Files and choose the recording:") == true {
            return "exclamationmark.triangle"
        }
        if track.spotifyStatus == .added { return "checkmark.circle.fill" }
        if track.spotifyStatus == .failed || track.stage == .failed { return "exclamationmark.triangle.fill" }
        if track.spotifyStatus == .pending { return "hourglass" }
        if track.savedPath != nil { return "checkmark.circle" }
        return "arrow.down.circle"
    }
}
