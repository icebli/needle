import Foundation
import Observation

struct ReleaseBookmark: Codable, Identifiable {
    let id: String
    let artist: String
    let title: String
    let album: String
    let candidate: Candidate
    let score: Score?
    let date: Date
    var artwork: ArtworkReference?

    init(artist: String, title: String, album: String = "", candidate: Candidate, score: Score? = nil, date: Date = .now, artwork: ArtworkReference? = nil) {
        self.id = candidate.provider + ":" + candidate.id
        self.artist = artist
        self.title = title
        self.album = album
        self.candidate = candidate
        self.score = score
        self.date = date
        self.artwork = artwork
    }
}

@MainActor @Observable
final class BookmarkStore {
    private(set) var items: [ReleaseBookmark] = []
    private let defaults: UserDefaults
    private let key = "needle.bookmarks"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([ReleaseBookmark].self, from: data) {
            items = decoded
        }
    }

    func contains(candidate: Candidate) -> Bool { items.contains { $0.id == candidate.provider + ":" + candidate.id } }

    func toggle(artist: String, title: String, album: String = "", candidate: Candidate, score: Score? = nil, artwork: ArtworkReference? = nil) {
        let id = candidate.provider + ":" + candidate.id
        if let index = items.firstIndex(where: { $0.id == id }) { items.remove(at: index) }
        else { items.insert(ReleaseBookmark(artist: artist, title: title, album: album, candidate: candidate, score: score, artwork: artwork), at: 0) }
        persist()
    }

    func remove(_ bookmark: ReleaseBookmark) {
        items.removeAll { $0.id == bookmark.id }
        persist()
    }

    @discardableResult
    func fillArtwork(_ artwork: ArtworkReference, for original: ReleaseBookmark) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == original.id }),
              items[index].date == original.date,
              items[index].candidate.url == original.candidate.url,
              items[index].candidate.title == original.candidate.title,
              items[index].candidate.durationMs == original.candidate.durationMs,
              items[index].candidate.thumbnailURL == original.candidate.thumbnailURL,
              items[index].artist == original.artist, items[index].title == original.title,
              items[index].album == original.album, items[index].artwork == nil else { return false }
        items[index].artwork = artwork
        persist()
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: key) }
    }
}
