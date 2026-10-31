import XCTest
@testable import NeedleDesktop

@MainActor
final class BookmarkStoreTests: XCTestCase {
    func testBookmarksPersistAndToggleByExactSource() {
        let suite = "NeedleBookmarks.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(defaults: defaults)
        let candidate = Candidate(provider: "youtube", id: "abc", url: "https://youtube.com/watch?v=abc", title: "Song", uploader: "Artist", durationMs: nil, thumbnailURL: nil)
        store.toggle(artist: "Artist", title: "Song", candidate: candidate)
        XCTAssertTrue(store.contains(candidate: candidate))
        let restored = BookmarkStore(defaults: defaults)
        XCTAssertEqual(restored.items.first?.artist, "Artist")
        XCTAssertEqual(restored.items.first?.candidate.url, candidate.url)
        restored.toggle(artist: "Artist", title: "Song", candidate: candidate)
        XCTAssertTrue(restored.items.isEmpty)
    }

    func testBookmarkReopensAsReadyQueueItemWithoutSearching() {
        let suite = "NeedleBookmarkQueue.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        let candidate = Candidate(provider: "youtube", id: "abc", url: "https://youtube.com/watch?v=abc", title: "Song upload", uploader: "Artist", durationMs: 180_000, thumbnailURL: nil)
        let bookmark = ReleaseBookmark(artist: "Artist", title: "Song", album: "Album", candidate: candidate)
        queue.addBookmark(bookmark, settings: NeedleSettings())
        XCTAssertEqual(queue.selected?.state, .ready)
        XCTAssertEqual(queue.selected?.sourceURL, candidate.url)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.url, candidate.url)
        XCTAssertEqual(queue.selected?.response?.metadata?.album, "Album")
    }

    func testArtworkResultCannotApplyAfterSourceEvidenceChanges() throws {
        let suite = "NeedleBookmarkEvidence.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = Candidate(provider: "youtube", id: "abc", url: "https://youtube.com/watch?v=abc", title: "Artist - Song", uploader: "Artist", durationMs: 180_000, thumbnailURL: "https://example.com/original.jpg")
        let original = ReleaseBookmark(artist: "Artist", title: "Song", candidate: candidate)
        let cover = ArtworkReference(url: "https://example.com/cover.jpg", provider: "source", releaseId: nil, releaseGroupId: nil)
        for field in ["title", "duration", "thumbnail"] {
            let changed = Candidate(provider: candidate.provider, id: candidate.id, url: candidate.url,
                title: field == "title" ? "Artist - Song (Live)" : candidate.title, uploader: candidate.uploader,
                durationMs: field == "duration" ? 240_000 : candidate.durationMs,
                thumbnailURL: field == "thumbnail" ? "https://example.com/changed.jpg" : candidate.thumbnailURL)
            let replacement = ReleaseBookmark(artist: original.artist, title: original.title, candidate: changed, date: original.date)
            defaults.set(try JSONEncoder().encode([replacement]), forKey: "needle.bookmarks")
            let updated = BookmarkStore(defaults: defaults)
            XCTAssertFalse(updated.fillArtwork(cover, for: original), field)
            XCTAssertNil(updated.items.first?.artwork)
        }
        defaults.set(try JSONEncoder().encode([original]), forKey: "needle.bookmarks")
        XCTAssertTrue(BookmarkStore(defaults: defaults).fillArtwork(cover, for: original))
    }
}
