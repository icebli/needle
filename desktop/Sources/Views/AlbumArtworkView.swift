import AppKit
import SwiftUI

struct AlbumArtworkView<Placeholder: View>: View {
    let artwork: ArtworkReference
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .accessibilityLabel(artwork.provider == "source" ? "Source upload artwork" : artwork.provider == "selected" ? "Selected cover image" : artwork.provider == "cover_art_archive" ? "Album artwork from Cover Art Archive" : "Album artwork from metadata")
                    .help(artwork.provider == "selected" ? "Selected image will be embedded after confirmation." : artwork.provider == "cover_art_archive"
                          ? "Album cover from Cover Art Archive. Source upload artwork is shown in the inspector."
                          : artwork.provider == "source" ? "Artwork from the selected source upload. No compatible catalog cover was found."
                          : "Album artwork from the metadata provider. Source upload artwork is shown in the inspector.")
            } else {
                placeholder()
            }
        }
        .task(id: artwork.url) {
            image = nil
            guard let url = AppModel.mediaURL(artwork.url),
                  let data = await AlbumArtworkCache.shared.data(for: url), !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }
}
