import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryRetryTests: XCTestCase {
    func testSharedSourceHasDistinctRowsAndRetryUpdatesTheSelectedArtist() async {
        let suite = "NeedleDiscoverySharedSource.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        let candidate = Candidate(provider: "youtube", id: "shared", url: "https://example.com/shared",
            title: "a & b - Song", uploader: nil, durationMs: nil, thumbnailURL: nil)
        store.recordings = ["a", "b"].map { id in
            DiscoveryRecording(artist: SpotifyArtist(id: id, name: id, uri: "spotify:artist:\(id)"),
                title: "Song", candidate: candidate, availability: .unknown)
        }
        XCTAssertEqual(Set(store.recordings.map(\.id)).count, 2)
        store.retryCatalog(store.recordings[1]) { _, _ in [] }
        await finish(store)
        XCTAssertEqual(store.recordings.map(\.availability), [.unknown, .noMatch])
    }

    func testFailedCheckStaysUnknownAndSuccessfulRetryFindsSpotifyRecording() async throws {
        let suite = "NeedleDiscoveryRetry.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        let artist = SpotifyArtist(id: "a", name: "Doechii", uri: "spotify:artist:a")
        let candidate = Candidate(provider: "soundcloud", id: "test", url: "https://soundcloud.com/test/song",
            title: "Nissan Altima", uploader: "Doechii", durationMs: nil, thumbnailURL: nil)
        let recording = DiscoveryRecording(artist: artist, title: candidate.title, candidate: candidate, availability: .unknown)
        store.recordings = [recording]
        store.retryCatalog(recording) { _, _ in throw CLIError.message("Timed out") }
        await finish(store)
        XCTAssertEqual(store.recordings.first?.availability, .unknown)
        XCTAssertEqual(store.recordings.first?.detail, "Timed out")
        XCTAssertTrue(store.catalogNotice?.contains("still unknown") == true)

        store.retryCatalog(recording) { _, _ in
            [SpotifyCatalogTrack(id: "song", name: "NISSAN ALTIMA", uri: "spotify:track:song",
                artists: [SpotifyArtistCredit(id: "a", name: "Doechii")])]
        }
        await finish(store)
        XCTAssertEqual(store.recordings.first?.availability, .found)
        XCTAssertEqual(store.recordings.first?.catalogURI, "spotify:track:song")
        XCTAssertTrue(store.catalogNotice?.contains("Found on Spotify") == true)

        store.retryCatalog(recording) { _, _ in [] }
        await finish(store)
        XCTAssertEqual(store.recordings.first?.availability, .noMatch)
        XCTAssertNil(store.recordings.first?.catalogURI)
    }

    private func finish(_ store: DiscoveryStore) async {
        for _ in 0..<100 where store.isSearching { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isSearching)
    }
}
