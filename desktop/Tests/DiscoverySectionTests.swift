import XCTest
@testable import NeedleDesktop

final class DiscoverySectionTests: XCTestCase {
    func testLiveHotlineBlingCatalogResponseMatchesTheReportedUpload() throws {
        let data = Data(#"{"id":"0wwPcA6wtMf6HUMpIRdeP7","name":"Hotline Bling","uri":"spotify:track:0wwPcA6wtMf6HUMpIRdeP7","artists":[{"id":"3TVXtAsR1Inumwj472S9r4","name":"Drake"}],"durationMs":267066}"#.utf8)
        let track = try JSONDecoder().decode(SpotifyCatalogTrack.self, from: data)
        let source = recording("Drake - Hotline Bling", availability: .unknown)
        XCTAssertEqual(DiscoveryMatching.matchingTrack([track], artist: source.artist, title: source.title)?.uri, track.uri)
    }

    func testUncheckedAndSpotifyMatchesNeverBecomeDiscoveryLeads() {
        let pending = recording("Hotline Bling", availability: .unknown)
        let found = recording("Hotline Bling", availability: .found)
        let lead = recording("Unreleased recording", availability: .noMatch)
        let rows = [pending, found, lead]
        XCTAssertEqual(DiscoverySection.leads.recordings(in: rows).map(\.title), [lead.title])
        XCTAssertEqual(DiscoverySection.unchecked.recordings(in: rows).map(\.title), [pending.title])
        XCTAssertEqual(DiscoverySection.onSpotify.recordings(in: rows).map(\.title), [found.title])
    }

    func testKnownCatalogSongsAreExcludedFromLeadsWithUploadLabels() {
        for title in ["Hotline Bling", "God's Plan", "One Dance"] {
            let artist = SpotifyArtist(id: "3TVXtAsR1Inumwj472S9r4", name: "Drake", uri: "spotify:artist:3TVXtAsR1Inumwj472S9r4")
            let tracks = [SpotifyCatalogTrack(id: "catalog", name: title, uri: "spotify:track:catalog",
                artists: [SpotifyArtistCredit(id: artist.id, name: artist.name)])]
            let sourceTitle = "Drake - \(title) (Official Video)"
            let match = DiscoveryMatching.matchingTrack(tracks, artist: artist, title: sourceTitle)
            XCTAssertNotNil(match, sourceTitle)
            let row = recording(sourceTitle, availability: match == nil ? .noMatch : .found)
            XCTAssertTrue(DiscoverySection.leads.recordings(in: [row]).isEmpty, sourceTitle)
        }
    }

    func testVersionSpecificLeadIsNotDiscardedAsItsStudioRecording() {
        let row = recording("Hotline Bling (Live)", availability: .unknown)
        let studio = SpotifyCatalogTrack(id: "studio", name: "Hotline Bling", uri: "spotify:track:studio",
            artists: [SpotifyArtistCredit(id: row.artist.id, name: row.artist.name)])
        XCTAssertNil(DiscoveryMatching.matchingTrack([studio], artist: row.artist, title: row.title))
    }

    private func recording(_ title: String, availability: CatalogAvailability) -> DiscoveryRecording {
        let artist = SpotifyArtist(id: "3TVXtAsR1Inumwj472S9r4", name: "Drake", uri: "spotify:artist:3TVXtAsR1Inumwj472S9r4")
        let candidate = Candidate(provider: "youtube", id: title, url: "https://example.com/source",
            title: title, uploader: "Drake", durationMs: nil, thumbnailURL: nil)
        return DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: availability)
    }
}
