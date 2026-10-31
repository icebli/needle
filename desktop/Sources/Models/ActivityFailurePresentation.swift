import Foundation

struct ActivityFailurePresentation {
    let statusLabel: String
    let summary: String
    let recovery: String
    let technicalDetail: String?

    init?(track: TrackRequest, canRetry: Bool = false) {
        guard track.stage == .failed || track.spotifyStatus == .failed || track.stage == .interrupted && track.approvedSave != nil else { return nil }
        technicalDetail = track.errorDetail.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let reason = Self.failureReason(in: technicalDetail)

        if reason?.localizedCaseInsensitiveContains("The returned recording differs from your approved source. Your file was kept") == true {
            statusLabel = "Save needs review"
            summary = "The returned recording differs from your approved source. Your file was kept."
            recovery = "Open Library and review the existing recording before approving another save."
        } else if track.savedPath == nil && track.saveRetrySafety == .requiresArtworkReview {
            statusLabel = "Artwork needs review"
            summary = reason ?? "The retained approved artwork is unavailable."
            recovery = "In Add Music, review and approve the artwork again. The original source and tags are retained in this activity."
        } else if track.savedPath == nil && track.saveNeedsLibraryReview {
            statusLabel = "Save needs review"
            summary = reason ?? "Needle stopped without confirming whether a file was saved."
            recovery = "Open Library and check for this recording before approving another save. Your original approval is retained."
        } else if track.savedPath == nil && canRetry {
            statusLabel = "File save failed"
            summary = reason ?? "Needle could not finish saving this recording."
            if track.approvedSave?.artwork == .pending {
                recovery = "Choose Retry to keep the approved source and tags and fetch the same artwork location. No audio save has started."
            } else {
                recovery = "Choose Retry to use the same approved source, tags, and artwork."
            }
        } else if track.savedPath == nil {
            statusLabel = "File save failed"
            if reason?.localizedCaseInsensitiveContains("approved artwork URL did not return a recognized image") == true {
                summary = "The artwork link did not return a usable image."
                recovery = "In Add Music, review the artwork and approve this recording again."
            } else {
                summary = reason ?? "Needle could not finish saving this recording. No failure reason was recorded."
                recovery = "In Add Music, review the source and track details, then approve this recording again."
            }
        } else if track.spotifyStatus == .failed {
            statusLabel = "File saved · Spotify needs attention"
            summary = reason ?? "Spotify delivery failed. No failure reason was recorded."
            if (track.settingsSnapshot?.format ?? "mp3") == "mp3" {
                let action = track.spotifyJobID == nil ? "Add to Spotify" : "Check Spotify"
                recovery = "Open Spotify and check Local Files, then choose \"\(action)\"."
            } else {
                recovery = "Spotify delivery needs an MP3. In Add Music, review and approve an MP3 save."
            }
        } else {
            statusLabel = "File saved · Needs attention"
            summary = reason ?? "Needle could not finish the operation. No failure reason was recorded."
            recovery = "Open this recording in Library and choose Repair to review its details."
        }
    }

    private static func failureReason(in detail: String?) -> String? {
        guard let detail else { return nil }
        let lines = detail.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil }
        guard var reason = lines.last(where: { $0.lowercased().hasPrefix("error:") }) ?? lines.first else { return nil }
        for prefix in ["Error:", "Your file is saved. Spotify delivery needs attention:",
                       "The file is updated. Spotify metadata repair needs attention:"] {
            if reason.lowercased().hasPrefix(prefix.lowercased()) {
                reason = String(reason.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard !reason.isEmpty else { return nil }
        return reason.count > 280 ? String(reason.prefix(280)) + "…" : reason
    }
}
