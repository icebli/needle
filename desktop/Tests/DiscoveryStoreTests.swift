import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryStoreTests: XCTestCase {
    func testRefreshAllRechecksEveryStatusAndPersistsResults() async throws {
        let suite = "NeedleRefreshAll.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.recordings = refreshRecordings()
        var titles: [String] = []
        store.refreshCatalog { _, title in
            titles.append(title)
            return title == "Song 0" ? [SpotifyCatalogTrack(id: "t", name: title, uri: "spotify:track:t",
                artists: [SpotifyArtistCredit(id: "a", name: "Artist")])] : []
        }
        // A second click while refreshing must not start overlapping bridge requests.
        store.refreshCatalog { _, _ in XCTFail("Overlapping refresh"); return [] }
        await finishRefresh(store)
        XCTAssertEqual(titles, ["Song 0", "Song 1", "Song 2"])
        XCTAssertEqual(store.recordings.map(\.availability), [.found, .noMatch, .noMatch])
        XCTAssertEqual(store.recordings.first?.catalogURI, "spotify:track:t")
        XCTAssertNil(store.recordings[1].catalogURI)
        XCTAssertEqual(store.recordings.map { $0.candidate.url }, refreshRecordings().map { $0.candidate.url })
        XCTAssertEqual(DiscoveryStore(defaults: defaults).recordings.map(\.availability), [.found, .noMatch, .noMatch])
        XCTAssertEqual(store.catalogNotice, "Refreshed 3 Spotify checks: 1 found, 2 without an exact match.")
    }

    func testRefreshAllStopsOnServiceFailureAndLeavesUncheckedResultsAlone() async {
        let suite = "NeedleRefreshFailure.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.recordings = refreshRecordings()
        var calls = 0
        store.refreshCatalog { _, _ in calls += 1; throw CLIError.message("Rate limited") }
        await finishRefresh(store)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.recordings.map(\.availability), [.unknown, .found, .unknown])
        XCTAssertEqual(store.recordings[0].detail, "Rate limited")
        XCTAssertTrue(store.catalogNotice?.contains("stopped after 0 of 3") == true)
    }

    func testRefreshAllCancellationKeepsCompletedResults() async {
        let suite = "NeedleRefreshCancel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.recordings = refreshRecordings()
        var calls = 0
        store.refreshCatalog { _, _ in calls += 1; return [] }
        for _ in 0..<100 where calls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        store.cancel()
        await finishRefresh(store)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.recordings.map(\.availability), [.noMatch, .found, .unknown])
        XCTAssertTrue(store.catalogNotice?.contains("Completed 1 of 3") == true)
    }

    private func refreshRecordings() -> [DiscoveryRecording] {
        let artist = SpotifyArtist(id: "a", name: "Artist", uri: "spotify:artist:a")
        return [CatalogAvailability.noMatch, .found, .unknown].enumerated().map { index, availability in
            let candidate = Candidate(provider: "youtube", id: "\(index)", url: "https://www.youtube.com/watch?v=\(index)",
                title: "Song \(index)", uploader: nil, durationMs: nil, thumbnailURL: nil)
            return DiscoveryRecording(artist: artist, title: candidate.title, candidate: candidate, availability: availability,
                catalogURI: availability == .found ? "spotify:track:old" : nil)
        }
    }

    func testRefreshAllUpdatesSameSourceUnderDifferentArtists() async {
        let suite = "NeedleRefreshCredits.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        let first = refreshRecordings()[0]
        let guest = SpotifyArtist(id: "guest", name: "Guest", uri: "spotify:artist:guest")
        store.recordings = [first, DiscoveryRecording(artist: guest, title: first.title, candidate: first.candidate, availability: .unknown)]
        store.refreshCatalog { _, title in
            [SpotifyCatalogTrack(id: "shared", name: title, uri: "spotify:track:shared", artists: [
                SpotifyArtistCredit(id: first.artist.id, name: first.artist.name), SpotifyArtistCredit(id: guest.id, name: guest.name)])]
        }
        await finishRefresh(store)
        XCTAssertEqual(store.recordings.map(\.availability), [.found, .found])
        XCTAssertEqual(store.recordings.map(\.artist.id), ["a", "guest"])
    }

    func testRefreshAllCancellationDuringFailingLookupDoesNotOverwriteResult() async {
        let suite = "NeedleRefreshPendingCancel.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.recordings = refreshRecordings()
        var resume: CheckedContinuation<Void, Never>?
        store.refreshCatalog { _, _ in
            await withCheckedContinuation { resume = $0 }
            throw CLIError.message("Companion failed after cancellation")
        }
        for _ in 0..<100 where resume == nil { try? await Task.sleep(for: .milliseconds(5)) }
        store.cancel()
        resume?.resume()
        await finishRefresh(store)
        XCTAssertEqual(store.recordings.map(\.availability), [.noMatch, .found, .unknown])
        XCTAssertTrue(store.catalogNotice?.contains("Completed 0 of 3") == true)
    }

    private func finishRefresh(_ store: DiscoveryStore) async {
        for _ in 0..<200 where store.isSearching { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.isSearching)
        XCTAssertTrue(store.progress.isEmpty)
    }

    func testLegacyEmptySnapshotDoesNotPretendSearchCompleted() throws {
        let suite = "NeedleDiscoveryStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "artists": [], "recordings": [], "lastSynced": NSNull(),
        ]), forKey: "needle.discovery")

        let store = DiscoveryStore(defaults: defaults)
        XCTAssertFalse(store.hasSearched)
        XCTAssertTrue(store.warnings.isEmpty)
        XCTAssertNil(store.error)
    }

    func testCompletedEmptySnapshotRestoresSearchStateWarningsAndError() throws {
        let suite = "NeedleDiscoveryStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "artists": [], "recordings": [], "lastSynced": NSNull(),
            "hasSearched": true,
            "warnings": ["YouTube search timed out."],
            "error": "Couldn’t search Drake. Check the source setup and try again.",
        ]), forKey: "needle.discovery")

        let store = DiscoveryStore(defaults: defaults)
        XCTAssertTrue(store.hasSearched)
        XCTAssertEqual(store.warnings, ["YouTube search timed out."])
        XCTAssertEqual(store.error, "Couldn’t search Drake. Check the source setup and try again.")
    }
}
