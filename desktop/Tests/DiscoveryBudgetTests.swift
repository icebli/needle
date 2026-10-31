import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryBudgetTests: XCTestCase {
    func testPerArtistDepthPreservesSingleArtistSearchDepth() {
        XCTAssertEqual(DiscoveryStore.candidatesPerArtist, 45)
    }

    func testEachArtistKeeps45EligibleUniqueRecordingsAfterFiltering() async throws {
        let suite = "NeedleDiscoveryDepth.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("NeedleLibrary.\(UUID())")
        try Data().write(to: saved)
        defer { try? FileManager.default.removeItem(at: saved) }
        let store = DiscoveryStore(defaults: defaults)
        store.artists = (0..<6).map { SpotifyArtist(id: "a\($0)", name: "Artist \($0)", uri: "spotify:artist:a\($0)") }
        store.selectedArtistIDs = Set(store.artists.map(\.id))
        let library = store.artists.map { TrackRequest(artist: $0.name, title: "Already saved", savedPath: saved.path) }
        store.find(settings: NeedleSettings(), library: library, sourceLookup: { artist in
            func candidate(_ id: String, title: String, url: String = "https://example.com/source") -> Candidate {
                Candidate(provider: "youtube", id: "\(artist)-\(id)", url: url, title: title,
                          uploader: artist, durationMs: nil, thumbnailURL: nil)
            }
            let excluded = (0..<50).map { candidate("library\($0)", title: "Already saved") }
                + [candidate("invalid", title: "Invalid URL", url: "file:///tmp/audio"), candidate("empty", title: "")]
            let duplicates = (0..<50).map { candidate("duplicate\($0)", title: "Song 0") }
            let eligible = (0..<46).map { candidate("valid\($0)", title: "Song \($0)") }
            return excluded + duplicates + eligible
        }, catalogLookup: { _, _ in throw CLIError.message("Catalog offline") })
        for _ in 0..<1_000 where store.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isSearching)
        XCTAssertEqual(store.recordings.count, 6 * 45)
        for artist in store.artists {
            let titles = store.recordings.filter { $0.artist.id == artist.id }.map(\.title)
            XCTAssertEqual(Set(titles), Set((0..<45).map { "Song \($0)" }))
        }
    }
    func testSearchProcessesEverySelectedArtistBeyondFive() async {
        let suite = "NeedleLargeSelection.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.artists = (0..<30).map { SpotifyArtist(id: "a\($0)", name: "Artist \($0)", uri: "spotify:artist:a\($0)") }
        store.selectedArtistIDs = Set(store.artists.map(\.id))
        var searched: [String] = []
        var progress: [String] = []
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            searched.append(artist)
            progress.append(store.progress)
            return []
        })
        for _ in 0..<200 where store.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isSearching)
        XCTAssertEqual(searched, store.artists.map(\.name))
        XCTAssertTrue(progress.last?.contains("30/30") == true)
        XCTAssertNil(store.error)
    }
}
