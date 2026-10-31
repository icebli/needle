import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryRunTests: XCTestCase {
    func testCatalogChecksFirstRecordingWhileLaterSourceIsPending() async {
        let (store, defaults, suite) = makeStore(artistCount: 2)
        defer { defaults.removePersistentDomain(forName: suite) }
        var resume: CheckedContinuation<Void, Never>?
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            if artist == "Artist 1" { await withCheckedContinuation { resume = $0 } }
            return [Candidate(provider: "youtube", id: artist, url: "https://example.com/\(UUID())",
                title: "\(artist) - Hotline Bling", uploader: artist, durationMs: nil, thumbnailURL: nil)]
        }, catalogLookup: { artist, title in
            [SpotifyCatalogTrack(id: "hotline", name: title, uri: "spotify:track:hotline",
                artists: [SpotifyArtistCredit(id: "a0", name: artist)])]
        })
        for _ in 0..<200 where resume == nil || store.run?.catalogChecked == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(resume)
        XCTAssertEqual(store.run?.artistsCompleted, 1)
        XCTAssertEqual(store.recordings.first?.title, "Hotline Bling")
        XCTAssertEqual(store.recordings.first?.availability, .found)
        XCTAssertEqual(store.recordings.first?.catalogURI, "spotify:track:hotline")
        XCTAssertTrue(store.runSummary?.contains("Spotify resolved 1 of 1; 0 unconfirmed.") == true)
        XCTAssertEqual(DiscoveryStore(defaults: defaults).recordings.first?.availability, .found)
        XCTAssertTrue(store.isSearching)
        resume?.resume()
        await finish(store)
        XCTAssertEqual(store.run?.artistsCompleted, 2)
        XCTAssertEqual(store.run?.catalogChecked, 2)
    }

    func testCatalogFailurePreservesSourceCoverageForAll100Artists() async {
        let suite = "NeedleDiscoveryRun.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DiscoveryStore(defaults: defaults)
        store.artists = (0..<100).map { SpotifyArtist(id: "a\($0)", name: "Artist \($0)", uri: "spotify:artist:a\($0)") }
        store.selectedArtistIDs = Set(store.artists.map(\.id))
        var sourceCalls: [String] = []
        var catalogCalls = 0
        var resume: CheckedContinuation<Void, Never>?
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            sourceCalls.append(artist)
            if artist == "Artist 1" { await withCheckedContinuation { resume = $0 } }
            return (0..<2).map { index in
                Candidate(provider: "youtube", id: "\(artist)-\(index)", url: "https://example.com/\(UUID())",
                          title: "\(artist) - Song \(index)", uploader: artist, durationMs: nil, thumbnailURL: nil)
            }
        }, catalogLookup: { _, _ in
            catalogCalls += 1
            throw CLIError.message("Spotify request timed out after 30 seconds")
        })
        for _ in 0..<200 where resume == nil || catalogCalls == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(resume)
        XCTAssertEqual(catalogCalls, 1)
        XCTAssertEqual(store.run?.artistsCompleted, 1)
        XCTAssertNotNil(store.run?.catalogFailure)
        XCTAssertNotNil(DiscoveryStore(defaults: defaults).run?.catalogFailure)
        XCTAssertTrue(store.isSearching)
        resume?.resume()
        await finish(store)
        XCTAssertFalse(store.isSearching)
        XCTAssertEqual(sourceCalls, store.artists.map(\.name))
        XCTAssertEqual(store.recordings.count, 200)
        XCTAssertTrue(store.recordings.allSatisfy { $0.availability == .unknown })
        XCTAssertEqual(catalogCalls, 1)
        XCTAssertEqual(store.run?.phase, .completed)
        XCTAssertEqual(store.run?.artistsAttempted, 100)
        XCTAssertEqual(store.run?.artistsCompleted, 100)
        XCTAssertEqual(store.run?.catalogChecked, 0)
        XCTAssertEqual(store.run?.selectedArtistIDs.count, 100)
        XCTAssertTrue(store.runNeedsAttention)
        XCTAssertTrue(store.runSummary?.contains("Open Spotify, then use Refresh all") == true)
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertEqual(reopened.run?.phase, .completed)
        XCTAssertEqual(reopened.run?.artistsCompleted, 100)
        XCTAssertEqual(reopened.run?.catalogChecked, 0)
        XCTAssertEqual(reopened.recordings.count, 200)
        XCTAssertEqual(reopened.selectedArtistIDs, store.selectedArtistIDs)
    }

    func testSourceFailureContinuesToLaterArtists() async {
        let (store, defaults, suite) = makeStore(artistCount: 3)
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [String] = []
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            calls.append(artist)
            if artist == "Artist 1" { throw CLIError.message("Source unavailable") }
            return [self.candidate(artist: artist, index: 0)]
        }, catalogLookup: { _, _ in [] })
        await finish(store)
        XCTAssertEqual(calls, store.artists.map(\.name))
        XCTAssertEqual(store.recordings.count, 2)
        XCTAssertTrue(store.recordings.allSatisfy { $0.availability == .noMatch })
        XCTAssertEqual(store.run?.artistsAttempted, 3)
        XCTAssertEqual(store.run?.artistsCompleted, 2)
        XCTAssertEqual(store.run?.sourceFailures, 1)
        XCTAssertEqual(store.run?.catalogChecked, 2)
        XCTAssertTrue(store.error?.contains("Artist 1") == true)
        XCTAssertTrue(store.runNeedsAttention)
        XCTAssertEqual(DiscoveryStore(defaults: defaults).run?.sourceFailures, 1)
    }

    func testCancellationKeepsCompletedSourcesAndFrozenSelection() async {
        let (store, defaults, suite) = makeStore(artistCount: 3)
        defer { defaults.removePersistentDomain(forName: suite) }
        let selected = store.selectedArtistIDs
        var calls = 0
        var catalogCalls = 0
        var resume: CheckedContinuation<Void, Never>?
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            calls += 1
            if calls == 2 { await withCheckedContinuation { resume = $0 } }
            return [self.candidate(artist: artist, index: 0)]
        }, catalogLookup: { _, _ in catalogCalls += 1; return [] })
        for _ in 0..<200 where resume == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(resume)
        store.selectedArtistIDs = []
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { _ in XCTFail("Overlapping search"); return [] })
        let completedCatalogCalls = catalogCalls
        store.cancel()
        resume?.resume()
        await finish(store)
        XCTAssertEqual(catalogCalls, completedCatalogCalls)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.run?.phase, .cancelled)
        XCTAssertEqual(store.run?.artistsAttempted, 2)
        XCTAssertEqual(store.run?.artistsCompleted, 1)
        XCTAssertEqual(Set(store.run?.selectedArtistIDs ?? []), selected)
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertEqual(reopened.run?.phase, .cancelled)
        XCTAssertEqual(reopened.recordings.count, 1)
        XCTAssertTrue(reopened.selectedArtistIDs.isEmpty)
    }

    func testCancellationWhileSourceAndCatalogArePendingPreventsLateWrites() async {
        let (store, defaults, suite) = makeStore(artistCount: 3)
        defer { defaults.removePersistentDomain(forName: suite) }
        var sourceResume: CheckedContinuation<Void, Never>?
        var catalogResume: CheckedContinuation<Void, Never>?
        var sourceCalls = 0
        var catalogCalls = 0
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            sourceCalls += 1
            if sourceCalls == 2 { await withCheckedContinuation { sourceResume = $0 } }
            return [self.candidate(artist: artist, index: 0)]
        }, catalogLookup: { _, _ in
            catalogCalls += 1
            await withCheckedContinuation { catalogResume = $0 }
            return []
        })
        for _ in 0..<200 where sourceResume == nil || catalogResume == nil {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertNotNil(sourceResume)
        XCTAssertNotNil(catalogResume)
        store.cancel()
        sourceResume?.resume()
        catalogResume?.resume()
        await finish(store)
        XCTAssertEqual(sourceCalls, 2)
        XCTAssertEqual(catalogCalls, 1)
        XCTAssertEqual(store.run?.phase, .cancelled)
        XCTAssertEqual(store.run?.artistsCompleted, 1)
        XCTAssertEqual(store.run?.catalogChecked, 0)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings.first?.availability, .unknown)
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertEqual(reopened.run?.phase, .cancelled)
        XCTAssertEqual(reopened.run?.artistsCompleted, 1)
        XCTAssertEqual(reopened.run?.catalogChecked, 0)
        XCTAssertEqual(reopened.recordings.count, 1)
        XCTAssertEqual(reopened.recordings.first?.availability, .unknown)
    }

    func testCancellationDuringCatalogRetainsCompletedChecks() async {
        let (store, defaults, suite) = makeStore(artistCount: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls = 0
        var resume: CheckedContinuation<Void, Never>?
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            (0..<3).map { self.candidate(artist: artist, index: $0) }
        }, catalogLookup: { _, _ in
            calls += 1
            if calls == 2 { await withCheckedContinuation { resume = $0 } }
            return []
        })
        for _ in 0..<200 where resume == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(resume)
        store.cancel()
        resume?.resume()
        await finish(store)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(store.recordings.map(\.availability), [.noMatch, .unknown, .unknown])
        XCTAssertEqual(store.run?.catalogChecked, 1)
        XCTAssertEqual(store.run?.phase, .cancelled)
        XCTAssertEqual(DiscoveryStore(defaults: defaults).recordings.map(\.availability), [.noMatch, .unknown, .unknown])
    }

    func testReopeningActiveRunMarksPersistedCheckpointInterrupted() async {
        let (store, defaults, suite) = makeStore(artistCount: 2)
        defer { defaults.removePersistentDomain(forName: suite) }
        var resume: CheckedContinuation<Void, Never>?
        store.find(settings: NeedleSettings(), library: [], sourceLookup: { artist in
            if artist == "Artist 1" { await withCheckedContinuation { resume = $0 } }
            return [self.candidate(artist: artist, index: 0)]
        }, catalogLookup: { _, _ in [] })
        for _ in 0..<200 where resume == nil { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(resume)
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertFalse(reopened.isSearching)
        XCTAssertEqual(reopened.run?.phase, .interrupted)
        XCTAssertEqual(reopened.run?.artistsAttempted, 2)
        XCTAssertEqual(reopened.run?.artistsCompleted, 1)
        XCTAssertEqual(reopened.recordings.count, 1)
        XCTAssertTrue(reopened.runNeedsAttention)
        XCTAssertTrue(reopened.runSummary?.contains("Search interrupted") == true)
        XCTAssertEqual(DiscoveryStore(defaults: defaults).run?.phase, .interrupted)
        store.cancel()
        resume?.resume()
        await finish(store)
    }

    func testLegacySnapshotKeepsCoverageUnknownAndExplicitEmptySelection() throws {
        let (store, defaults, suite) = makeStore(artistCount: 100)
        defer { defaults.removePersistentDomain(forName: suite) }
        let artists = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.artists))
        defaults.set(try JSONSerialization.data(withJSONObject: ["artists": artists, "recordings": [],
            "hasSearched": true, "selectedArtistIDs": []]), forKey: "needle.discovery")
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertTrue(reopened.hasSearched)
        XCTAssertTrue(reopened.selectedArtistIDs.isEmpty)
        XCTAssertNil(reopened.run)
        XCTAssertEqual(reopened.runSummary, "Previous search coverage is unknown. Find recordings to search your selection.")
        XCTAssertTrue(reopened.runNeedsAttention)
    }

    func testSourceNoticesRemainVisibleAfterReopen() throws {
        let (store, defaults, suite) = makeStore(artistCount: 1)
        defer { defaults.removePersistentDomain(forName: suite) }
        let artists = try JSONSerialization.jsonObject(with: JSONEncoder().encode(store.artists))
        let run = DiscoveryStore.Run(phase: .completed, selectedArtistIDs: ["a0"], artistsAttempted: 1,
            artistsCompleted: 1, sourceNotices: 3)
        let runJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(run))
        defaults.set(try JSONSerialization.data(withJSONObject: ["artists": artists, "recordings": [],
            "hasSearched": true, "run": runJSON]), forKey: "needle.discovery")
        let reopened = DiscoveryStore(defaults: defaults)
        XCTAssertTrue(reopened.runNeedsAttention)
        XCTAssertTrue(reopened.runSummary?.contains("3 source search notices; coverage may be incomplete") == true)
    }

    private func makeStore(artistCount: Int) -> (DiscoveryStore, UserDefaults, String) {
        let suite = "NeedleDiscoveryRun.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = DiscoveryStore(defaults: defaults)
        store.artists = (0..<artistCount).map { SpotifyArtist(id: "a\($0)", name: "Artist \($0)", uri: "spotify:artist:a\($0)") }
        store.selectedArtistIDs = Set(store.artists.map(\.id))
        return (store, defaults, suite)
    }

    private func candidate(artist: String, index: Int) -> Candidate {
        Candidate(provider: "youtube", id: "\(artist)-\(index)", url: "https://example.com/\(UUID())",
                  title: "\(artist) - Song \(index)", uploader: artist, durationMs: nil, thumbnailURL: nil)
    }

    private func finish(_ store: DiscoveryStore) async {
        for _ in 0..<1_000 where store.isSearching { try? await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isSearching)
        XCTAssertTrue(store.progress.isEmpty)
    }
}
