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
            if model.history.tracks.isEmpty {
                ContentUnavailableView("Your collection starts here", systemImage: "tray",
                                       description: Text("Find and approve a recording in Add Music."))
            } else {
                List(model.history.tracks) { track in TrackRow(track: track, model: model) }.listStyle(.inset)
            }
        }.padding(32)
    }
}

struct TrackRow: View {
    let track: TrackRequest
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: track.savedPath == nil ? "waveform" : "music.note")
                    .font(.title2).foregroundStyle(.orange).frame(width: 34)
                VStack(alignment: .leading, spacing: 5) {
                    Text(track.title).font(.headline)
                    Text(track.artist + (track.album.isEmpty ? "" : " · \(track.album)")).foregroundStyle(.secondary)
                    Text(activityLabel(for: track)).font(.callout.weight(.medium))
                    if let path = track.savedPath { Text(path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
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
                DisclosureGroup("Details") { Text(detail).font(.caption).textSelection(.enabled) }.font(.caption)
            }
        }.padding(.vertical, 12)
    }

    private func activityLabel(for track: TrackRequest) -> String {
        guard track.spotifyStatus == .pending,
              let playlist = track.spotifyPlaylistName,
              track.savedPath != nil else { return track.stage.label }
        return "File saved · Waiting for Spotify to add to \"\(playlist)\""
    }
}
