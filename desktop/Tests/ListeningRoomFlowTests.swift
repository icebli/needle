import XCTest
@testable import NeedleDesktop

@MainActor
final class ListeningRoomFlowTests: XCTestCase {
    func testAReopenedBookmarkKeepsTheExactSourceURL() {
        let suite = "NeedleListeningRoomBookmark.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        let candidate = Candidate(provider: "youtube", id: "same-id", url: "https://example.com/source?version=2",
                                  title: "Song (live)", uploader: "Archive", durationMs: 180_000, thumbnailURL: nil)
        let bookmark = ReleaseBookmark(artist: "Artist", title: "Song", album: "Album", candidate: candidate)

        queue.addBookmark(bookmark, settings: NeedleSettings())

        XCTAssertEqual(queue.selected?.state, .ready)
        XCTAssertEqual(queue.selected?.sourceURL, candidate.url)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.url, candidate.url)
    }

    func testSaveRejectsSameCandidateIDWhenSourceURLChanges() {
        let suite = "NeedleListeningRoomIdentity.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        model.requestSnapshot = RequestSnapshot(artist: "Artist", title: "Song", album: "", sourceURL: "", settings: model.settings.value)
        let score = Score(confidence: 0.9, status: "recommended", positives: [], warnings: [], rejects: [])
        let current = CandidateResult(candidate: Candidate(provider: "youtube", id: "same-id", url: "https://example.com/current",
                                                            title: "Song", uploader: "Artist", durationMs: 180_000, thumbnailURL: nil), score: score)
        let stale = CandidateResult(candidate: Candidate(provider: "youtube", id: "same-id", url: "https://example.com/stale",
                                                          title: "Song", uploader: "Artist", durationMs: 180_000, thumbnailURL: nil), score: score)
        model.searchResults = [current]

        let approved = MetadataDraft(artist: "Artist", title: "Song", album: "", albumArtist: "Artist",
                                     artworkURL: "", source: "manual", warnings: [], sourceURL: stale.candidate.url)
        model.save(candidate: stale, queueSpotify: false, approved: approved)

        XCTAssertTrue(model.history.tracks.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.message, "Choose an eligible recording from the current search.")
    }
}
