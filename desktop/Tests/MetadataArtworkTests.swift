import XCTest
@testable import NeedleDesktop

@MainActor
final class MetadataArtworkTests: XCTestCase {
    func testCoverSelectionSupportsRemoteAndLocalImagesWithoutChangingSource() {
        var draft = MetadataDraft(artist: "Artist", title: "Song", album: "", albumArtist: "Artist", artworkURL: "https://example.org/cover.png", source: "musicbrainz", warnings: [], sourceURL: "https://example.org/song")
        XCTAssertEqual(draft.artworkLocation?.scheme, "https")
        draft.artworkURL = URL(fileURLWithPath: "/tmp/My Cover.png").absoluteString
        XCTAssertEqual(draft.artworkLocation?.path, "/tmp/My Cover.png")
        XCTAssertEqual(draft.sourceURL, "https://example.org/song")
        for invalid in ["file://remote.example/cover.png", "javascript:alert(1)", "ftp://example.org/cover.png", ""] {
            draft.artworkURL = invalid
            XCTAssertNil(draft.artworkLocation)
        }
    }
}
