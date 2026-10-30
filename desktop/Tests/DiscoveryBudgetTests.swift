import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryBudgetTests: XCTestCase {
    func testCatalogBudgetIsSharedAcrossSelectedArtists() {
        for artistCount in 1...100 {
            let limit = DiscoveryStore.candidateLimit(artistCount: artistCount)
            XCTAssertGreaterThan(limit, 0)
            XCTAssertLessThanOrEqual(limit * artistCount, max(45, artistCount))
        }
        XCTAssertEqual(DiscoveryStore.candidateLimit(artistCount: 1), 45)
        XCTAssertEqual(DiscoveryStore.candidateLimit(artistCount: 5), 9)
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
        store.find(settings: NeedleSettings(), library: []) { artist in
            searched.append(artist)
            progress.append(store.progress)
            return []
        }
        for _ in 0..<200 where store.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isSearching)
        XCTAssertEqual(searched, store.artists.map(\.name))
        XCTAssertTrue(progress.last?.contains("30/30") == true)
        XCTAssertNil(store.error)
    }
}
