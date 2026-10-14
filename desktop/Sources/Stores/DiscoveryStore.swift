import Foundation
import Observation

@MainActor @Observable
final class DiscoveryStore {
    var artists: [SpotifyArtist] = []
    var selectedArtistIDs: Set<String> = []
    var recordings: [DiscoveryRecording] = []
    var isSyncing = false
    var isSearching = false
    var progress = ""
    var error: String?
    var warnings: [String] = []
    var lastSynced: Date?
    private let spotify = SpotifyDiscoveryService()
    private let cli = NeedleCLIService()
    private var task: Task<Void, Never>?
    private let defaults: UserDefaults

    private struct Snapshot: Codable {
        let artists: [SpotifyArtist]
        let recordings: [DiscoveryRecording]
        let lastSynced: Date?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "needle.discovery"), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            artists = value.artists; recordings = value.recordings; lastSynced = value.lastSynced
            selectedArtistIDs = Set(artists.prefix(3).map(\.id))
        }
    }

    func sync() {
        guard !isSyncing, !isSearching else { return }
        isSyncing = true; error = nil
        task = Task {
            defer { isSyncing = false }
            do {
                let value = try await spotify.topArtists()
                guard !Task.isCancelled else { return }
                artists = value; selectedArtistIDs = Set(value.prefix(3).map(\.id)); lastSynced = .now
                persist()
            } catch { self.error = error.localizedDescription }
        }
    }

    func find(settings: NeedleSettings, library: [TrackRequest]) {
        guard !isSearching, !isSyncing else { return }
        let selection = Array(artists.filter { selectedArtistIDs.contains($0.id) }.prefix(5))
        guard !selection.isEmpty else { error = "Select up to five artists to search."; return }
        isSearching = true; error = nil; warnings = []; recordings = []
        task = Task {
            defer { isSearching = false; progress = ""; persist() }
            var seen = Set<String>()
            for artist in selection {
                guard !Task.isCancelled else { return }
                progress = "Finding popular uploads for \(artist.name)…"
                struct Sources: Decodable { let ok: Bool; let candidates: [Candidate]; let warnings: [String]? }
                do {
                    let data = try await cli.runJSONCommand(["discover", artist.name, "--json", "--source", settings.provider], settings: settings)
                    let response = try NeedleCLIService.parseLastJSON(Sources.self, data: data)
                    guard response.ok else { throw CLIError.message("Source search failed for \(artist.name).") }
                    warnings.append(contentsOf: response.warnings ?? [])
                    for candidate in response.candidates.prefix(Self.candidateLimit(artistCount: selection.count)) {
                        guard !Task.isCancelled else { return }
                        let title = DiscoveryMatching.title(candidate.title, artist: artist.name)
                        let key = artist.id + ":" + DiscoveryMatching.normalized(title)
                        guard !title.isEmpty, AppModel.mediaURL(candidate.url) != nil,
                              !seen.contains(key),
                              !DiscoveryMatching.isInLibrary(candidate: candidate, artist: artist.name, title: title, tracks: library) else { continue }
                        seen.insert(key)
                        progress = "Checking Spotify: \(artist.name) — \(title)"
                        var result = DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .unknown)
                        do {
                            let tracks = try await spotify.catalog(artist: artist.name, title: title)
                            if let match = DiscoveryMatching.matchingTrack(tracks, artist: artist, title: title) {
                                result = DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .found, catalogURI: match.uri)
                            } else {
                                result = DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .noMatch,
                                    detail: "No exact artist/title match in Spotify’s search results. Availability varies by region; check version names before approving.")
                            }
                        } catch {
                            result.detail = error.localizedDescription
                            warnings.append("Spotify catalog check stopped: \(error.localizedDescription)")
                            recordings.append(result)
                            // A failed authentication/rate-limit check is not evidence
                            // of absence. Stop rather than hammering the same service.
                            return
                        }
                        recordings.append(result)
                        try await Task.sleep(for: .milliseconds(350))
                    }
                } catch is CancellationError { return }
                catch { warnings.append("\(artist.name): \(error.localizedDescription)") }
            }
            recordings.sort { ($0.candidate.viewCount ?? 0) > ($1.candidate.viewCount ?? 0) }
        }
    }

    static func candidateLimit(artistCount: Int) -> Int {
        45 / max(1, min(artistCount, 5))
    }

    func cancel() {
        task?.cancel()
        Task { await cli.cancel() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Snapshot(artists: artists, recordings: recordings, lastSynced: lastSynced)) {
            defaults.set(data, forKey: "needle.discovery")
        }
    }
}
