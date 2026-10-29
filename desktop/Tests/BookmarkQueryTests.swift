import XCTest
@testable import NeedleDesktop

final class BookmarkQueryTests: XCTestCase {
    private func bookmark(_ id: String, artist: String = "Artist", title: String = "Song",
                          provider: String = "youtube", date: TimeInterval = 0) -> ReleaseBookmark {
        ReleaseBookmark(artist: artist, title: title, album: "Collected Sessions",
                        candidate: Candidate(provider: provider, id: id, url: "https://example.com/\(id)",
                                             title: "Live session", uploader: "Archive Channel",
                                             durationMs: nil, thumbnailURL: nil),
                        date: Date(timeIntervalSince1970: date))
    }

    func testSearchMatchesWordsAcrossSavedMetadataAndSourceFacts() {
        let match = bookmark("match", artist: "Beyoncé", title: "Déjà Vu")
        let other = bookmark("other", artist: "Another Artist")
        let query = BookmarkQuery(text: "  BEYONCE\n deja sessions archive live youtube  ")
        XCTAssertEqual(query.apply(to: [other, match]).map(\.id), [match.id])
        XCTAssertTrue(BookmarkQuery(text: "Beyonce missing").apply(to: [match]).isEmpty)
    }

    func testProviderFilterComposesWithSearchAndSupportsUnknownProviders() {
        let youtube = bookmark("a")
        let soundcloud = bookmark("b", provider: "soundcloud")
        let bandcamp = bookmark("c", provider: "bandcamp")
        let values = [youtube, soundcloud, bandcamp]
        XCTAssertEqual(BookmarkQuery(text: "Song", provider: "soundcloud").apply(to: values).map(\.id), [soundcloud.id])
        XCTAssertEqual(BookmarkQuery(provider: "bandcamp").apply(to: values).map(\.id), [bandcamp.id])
        XCTAssertTrue(BookmarkQuery(provider: "unavailable").apply(to: values).isEmpty)
    }

    func testWhitespaceQueryIncludesAllSources() {
        let values = [bookmark("a"), bookmark("b", provider: "soundcloud")]
        XCTAssertEqual(Set(BookmarkQuery(text: " \n\t ").apply(to: values).map(\.id)), Set(values.map(\.id)))
        XCTAssertTrue(BookmarkQuery().apply(to: []).isEmpty)
    }

    func testEverySortHasStableOrderAndDoesNotChangeInput() {
        let a = bookmark("a", artist: "Zulu", title: "Track 2", date: 20)
        let b = bookmark("b", artist: "Alpha", title: "Track 10", date: 10)
        let c = bookmark("c", artist: "Alpha", title: "Track 1", date: 20)
        let input = [b, c, a]
        XCTAssertEqual(BookmarkQuery(sort: .newest).apply(to: input).map(\.id), [a.id, c.id, b.id])
        XCTAssertEqual(BookmarkQuery(sort: .oldest).apply(to: input).map(\.id), [b.id, a.id, c.id])
        XCTAssertEqual(BookmarkQuery(sort: .artist).apply(to: input).map(\.id), [c.id, b.id, a.id])
        XCTAssertEqual(BookmarkQuery(sort: .title).apply(to: input).map(\.id), [c.id, a.id, b.id])
        XCTAssertEqual(input.map(\.id), [b.id, c.id, a.id])
        let tied = [bookmark("z"), bookmark("a")]
        for sort in BookmarkSort.allCases {
            XCTAssertEqual(BookmarkQuery(sort: sort).apply(to: tied).map(\.id), ["youtube:a", "youtube:z"])
        }
    }

    @MainActor
    func testFilteredActionsRetainExactSourceAndPersistenceOrder() throws {
        let suite = "NeedleBookmarkQuery.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BookmarkStore(defaults: defaults)
        let a = bookmark("shared", artist: "Target", provider: "youtube")
        let b = bookmark("shared", artist: "Target", provider: "soundcloud")
        store.toggle(artist: a.artist, title: a.title, candidate: a.candidate)
        store.toggle(artist: b.artist, title: b.title, candidate: b.candidate)
        let before = try XCTUnwrap(defaults.data(forKey: "needle.bookmarks"))
        let visible = BookmarkQuery(text: "Target", provider: "youtube", sort: .artist).apply(to: store.items)
        let selected = try XCTUnwrap(visible.first)
        let queue = ReviewQueue(defaults: defaults, history: HistoryStore(defaults: defaults))
        queue.addBookmark(selected, settings: NeedleSettings())
        XCTAssertEqual(queue.selected?.sourceURL, a.candidate.url)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.provider, "youtube")
        XCTAssertEqual(queue.selected?.state, .ready)
        XCTAssertEqual(defaults.data(forKey: "needle.bookmarks"), before)
        store.remove(selected)
        XCTAssertEqual(BookmarkStore(defaults: defaults).items.map(\.id), [b.id])
    }
}
