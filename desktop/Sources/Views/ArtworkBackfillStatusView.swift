import SwiftUI

struct ArtworkBackfillStatusView: View {
    let model: AppModel

    var body: some View {
        if model.artworkBackfill.isRunning {
            ProgressView().controlSize(.small)
            Text("Covers \(model.artworkBackfill.checked)/\(model.artworkBackfill.total)")
                .font(.caption).foregroundStyle(.secondary)
            Button("Stop") { model.artworkBackfill.stop() }
                .accessibilityLabel("Stop finding missing covers")
        } else {
            Button(model.artworkBackfill.isPaused ? "Resume covers" : "Find missing covers") {
                model.refreshArtwork(retry: true)
            }
            .help("Fill missing covers for bookmarks and saved recordings. Existing images and track details are preserved.")
            if model.artworkBackfill.filled > 0 {
                Text("\(model.artworkBackfill.filled) covers added").font(.caption).foregroundStyle(.secondary)
            }
            if model.artworkBackfill.unavailable > 0 {
                Label("\(model.artworkBackfill.unavailable) still missing", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .help(missingCoverDetails)
                    .accessibilityLabel("\(model.artworkBackfill.unavailable) covers still missing. \(missingCoverDetails)")
            }
        }
    }

    private var missingCoverDetails: String {
        let service = model.artworkBackfill
        var details: [String] = []
        if service.needsMetadataReview > 0 {
            details.append("\(service.needsMetadataReview) need metadata review because the source or recording details conflict. Check the artist, title, and album. For saved recordings, open Repair in Library.")
        }
        if service.missingSourceEvidence > 0 {
            details.append("\(service.missingSourceEvidence) have no independent source details to verify a cover safely.")
        }
        if service.catalogMisses > 0 {
            details.append("\(service.catalogMisses) have no verified catalog cover.")
        }
        if service.temporaryFailures > 0 {
            details.append("\(service.temporaryFailures) cover lookups failed temporarily. Needle will retry these later.")
        }
        if service.unspecifiedMisses > 0 {
            details.append("\(service.unspecifiedMisses) returned no cover without a specific reason.")
        }
        return details.joined(separator: "\n")
    }
}
