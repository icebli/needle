import XCTest
@testable import NeedleDesktop

@MainActor
final class MetadataArtworkTests: XCTestCase {
    func testEmptyReviewArtworkDefaultsToExactSourceThumbnailWithoutChangingMetadata() {
        let candidate = sourceCandidate()
        for artwork in ["", " \n\t"] {
            for suppressed in [nil, false] as [Bool?] {
                var draft = metadataDraft(artworkURL: artwork)
                draft.artworkSuppressed = suppressed

                let reviewed = draft.applyingDefaultSourceArtwork(from: candidate)

                XCTAssertEqual(reviewed.artworkURL, "https://i.ytimg.com/vi/fUiZ5vz9pUw/maxresdefault.jpg")
                XCTAssertEqual(reviewed.artworkLocation?.absoluteString, candidate.thumbnailURL)
                XCTAssertEqual(reviewed.artist, draft.artist)
                XCTAssertEqual(reviewed.title, draft.title)
                XCTAssertEqual(reviewed.album, draft.album)
                XCTAssertEqual(reviewed.albumArtist, draft.albumArtist)
                XCTAssertEqual(reviewed.source, draft.source)
                XCTAssertEqual(reviewed.sourceURL, draft.sourceURL)
                XCTAssertEqual(reviewed.warnings, draft.warnings)
                XCTAssertEqual(reviewed.artworkSuppressed, suppressed)
            }
        }
    }

    func testReviewArtworkPreservesAuthoritativeAndManualCovers() {
        for artwork in ["https://coverartarchive.org/release/cover.jpg", "https://example.org/custom.png",
                        URL(fileURLWithPath: "/tmp/My Cover.png").absoluteString] {
            let reviewed = metadataDraft(artworkURL: artwork)
                .applyingDefaultSourceArtwork(from: sourceCandidate())

            XCTAssertEqual(reviewed.artworkURL, artwork)
        }
    }

    func testExplicitlyClearedArtworkStaysEmptyWhenReviewDefaultsAreAppliedAgain() {
        let candidate = sourceCandidate()
        var draft = metadataDraft().applyingDefaultSourceArtwork(from: candidate)
        draft.artworkURL = ""
        draft.artworkSuppressed = true

        let reviewed = draft.applyingDefaultSourceArtwork(from: candidate)

        XCTAssertEqual(reviewed.artworkURL, "")
        XCTAssertEqual(reviewed.artworkSuppressed, true)
    }

    func testReviewArtworkRequiresTheSelectedSourceToMatchTheDraft() {
        let candidate = sourceCandidate(url: "https://www.youtube.com/watch?v=another-recording")

        let reviewed = metadataDraft().applyingDefaultSourceArtwork(from: candidate)

        XCTAssertEqual(reviewed.artworkURL, "")
    }

    func testReviewArtworkRejectsMissingOrNonHTTPSourceThumbnails() {
        for thumbnail in [nil, "", "not a URL", "file:///tmp/cover.jpg", "ftp://example.org/cover.jpg",
                          "javascript:alert(1)"] as [String?] {
            let reviewed = metadataDraft()
                .applyingDefaultSourceArtwork(from: sourceCandidate(thumbnailURL: thumbnail))

            XCTAssertEqual(reviewed.artworkURL, "")
        }
    }

    func testReviewArtworkAcceptsHTTPSourceThumbnails() {
        let candidate = sourceCandidate(thumbnailURL: "http://example.org/cover.jpg")

        let reviewed = metadataDraft().applyingDefaultSourceArtwork(from: candidate)

        XCTAssertEqual(reviewed.artworkURL, "http://example.org/cover.jpg")
    }

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

    private func metadataDraft(artworkURL: String = "") -> MetadataDraft {
        MetadataDraft(artist: "Wiz Khalifa", title: "MAAN Weedmix", album: "", albumArtist: "Wiz Khalifa",
                      artworkURL: artworkURL, source: "source-derived", warnings: ["No authoritative cover found."],
                      sourceURL: "https://www.youtube.com/watch?v=fUiZ5vz9pUw")
    }

    private func sourceCandidate(url: String = "https://www.youtube.com/watch?v=fUiZ5vz9pUw",
                                 thumbnailURL: String? = "https://i.ytimg.com/vi/fUiZ5vz9pUw/maxresdefault.jpg") -> Candidate {
        Candidate(provider: "youtube", id: "fUiZ5vz9pUw", url: url, title: "Wiz Khalifa - MAAN (Weedmix)",
                  uploader: "Wiz Khalifa", durationMs: nil, thumbnailURL: thumbnailURL)
    }
}
