import SwiftUI

struct MetadataDraft: Codable, Identifiable {
    var artist: String
    var title: String
    var album: String
    var albumArtist: String
    var artworkURL: String
    var source: String
    var warnings: [String]
    let sourceURL: String

    var id: String { sourceURL }

    enum CodingKeys: String, CodingKey {
        case artist
        case title
        case album
        case albumArtist = "album_artist"
        case artworkURL = "artwork_url"
        case source
        case warnings
        case sourceURL = "source_url"
    }
}

struct MetadataReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MetadataDraft

    let candidate: CandidateResult
    let onCancel: () -> Void
    let onConfirm: (MetadataDraft) -> Void

    init(draft: MetadataDraft, candidate: CandidateResult, onCancel: @escaping () -> Void,
         onConfirm: @escaping (MetadataDraft) -> Void) {
        _draft = State(initialValue: draft)
        self.candidate = candidate
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Review metadata before saving").font(.title2.weight(.semibold))
                    Text("Needle will use these tags for the downloaded recording.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.escape)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    artworkSection
                    metadataFields
                    provenanceSection
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.escape)
                Button("Confirm and save", action: confirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canConfirm)
            }
        }
        .padding(24)
        .frame(minWidth: 620, minHeight: 560)
    }

    private var artworkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Release artwork").font(.headline)
            HStack(alignment: .top, spacing: 14) {
                if let artworkURL = AppModel.mediaURL(draft.artworkURL), !draft.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    AsyncImage(url: artworkURL) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .empty: ProgressView()
                        case .failure: artworkMissing
                        @unknown default: artworkMissing
                        }
                    }
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Release artwork preview")
                } else {
                    artworkMissing
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(draft.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                         ? "No release artwork found. This recording will save without embedded cover art."
                         : "This is metadata artwork, not the source upload thumbnail.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("Artwork URL (optional)", text: $draft.artworkURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Release artwork URL")
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    private var artworkMissing: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.quaternary)
            .frame(width: 112, height: 112)
            .overlay {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("No release artwork available")
    }

    private var metadataFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tags").font(.headline)
            field("Artist", text: $draft.artist)
            field("Title", text: $draft.title)
            field("Album", text: $draft.album)
            field("Album artist", text: $draft.albumArtist)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).frame(width: 100, alignment: .trailing).foregroundStyle(.secondary)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel(label)
        }
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata source").font(.headline)
            Label(draft.source.isEmpty ? "Source not reported" : draft.source,
                  systemImage: "checkmark.seal")
                .foregroundStyle(.secondary)
            if !draft.warnings.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(draft.warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            if let sourceURL = AppModel.mediaURL(draft.sourceURL) {
                Link(destination: sourceURL) {
                    Label("Open source recording", systemImage: "arrow.up.right.square")
                }
                .accessibilityLabel("Open source recording")
            }
        }
    }

    private var canConfirm: Bool {
        let artist = draft.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artwork = draft.artworkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !artist.isEmpty && !title.isEmpty &&
            (artwork.isEmpty || AppModel.mediaURL(artwork) != nil)
    }

    private func cancel() {
        onCancel()
        dismiss()
    }

    private func confirm() {
        onConfirm(draft)
        dismiss()
    }
}
