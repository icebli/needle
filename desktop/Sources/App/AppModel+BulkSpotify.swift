import Foundation

/// The result of a user-requested bulk Spotify handoff.
struct BulkSpotifySummary: Equatable {
    let queued: Int
    let alreadyAdded: Int
    let inFlight: Int
    let missing: Int
    let unsupported: Int

    var skipped: Int { alreadyAdded + inFlight + missing + unsupported }

    var message: String {
        var details: [String] = []
        if alreadyAdded > 0 { details.append("\(alreadyAdded) already added") }
        if inFlight > 0 { details.append("\(inFlight) already waiting") }
        if missing > 0 { details.append("\(missing) missing") }
        if unsupported > 0 { details.append("\(unsupported) non-MP3") }
        let skippedText = details.isEmpty ? "" : " (\(details.joined(separator: ", ")) skipped)"
        if queued == 0 { return "No recordings were added to Spotify.\(skippedText)" }
        return "Queued \(queued) recording\(queued == 1 ? "" : "s") for Spotify.\(skippedText)"
    }
}

extension AppModel {
    /// Queue every eligible Library recording using the same per-track delivery
    /// path as the individual Activity action. This method only hands off files;
    /// it never downloads or silently retries a job already in progress.
    @discardableResult
    func enqueueAllLibraryTracksToSpotify(enqueueTrack: ((TrackRequest) -> Void)? = nil) -> BulkSpotifySummary {
        var queued = 0
        var alreadyAdded = 0
        var inFlight = 0
        var missing = 0
        var unsupported = 0

        for track in history.tracks {
            guard let path = track.savedPath, !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                missing += 1
                continue
            }
            guard track.settingsSnapshot?.format ?? "mp3" == "mp3" else {
                unsupported += 1
                continue
            }
            if track.spotifyStatus == .added {
                alreadyAdded += 1
                continue
            }
            if track.spotifyJobID != nil || pollingJobIDs.contains(track.id) || track.spotifyStatus == .pending {
                inFlight += 1
                continue
            }

            if let enqueueTrack { enqueueTrack(track) } else { enqueue(track) }
            queued += 1
        }

        let summary = BulkSpotifySummary(queued: queued, alreadyAdded: alreadyAdded,
                                         inFlight: inFlight, missing: missing,
                                         unsupported: unsupported)
        message = summary.message
        return summary
    }
}
