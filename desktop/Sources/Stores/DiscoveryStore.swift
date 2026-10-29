import Foundation
import Observation

@MainActor @Observable
final class DiscoveryStore {
    var artists: [SpotifyArtist] = []
    var selectedArtistIDs: Set<String> = []
    var recordings: [DiscoveryRecording] = []
    var isSyncing = false
    var isSearching = false
    var hasSearched = false
    var progress = ""
    var error: String?
    var warnings: [String] = []
    var catalogNotice: String?
    var lastSynced: Date?
    private let spotify = SpotifyDiscoveryService()
    private let cli = NeedleCLIService()
    private var task: Task<Void, Never>?
    private let defaults: UserDefaults

    private struct Snapshot: Codable {
        let artists: [SpotifyArtist]
        let recordings: [DiscoveryRecording]
        let lastSynced: Date?
        let hasSearched: Bool?
        let warnings: [String]?
        let error: String?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "needle.discovery"), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            artists = value.artists; recordings = value.recordings; lastSynced = value.lastSynced
            hasSearched = value.hasSearched ?? !value.recordings.isEmpty
            warnings = value.warnings ?? []
            error = value.error
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
        isSearching = true; hasSearched = true; error = nil; catalogNotice = nil; warnings = []; recordings = []
        task = Task {
            defer { isSearching = false; progress = ""; persist() }
            var seen = Set<String>()
            var sourceFailures: [String] = []
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
                catch {
                    warnings.append("\(artist.name): \(error.localizedDescription)")
                    sourceFailures.append(artist.name)
                }
            }
            recordings.sort { ($0.candidate.viewCount ?? 0) > ($1.candidate.viewCount ?? 0) }
            if !sourceFailures.isEmpty {
                error = "Couldn’t search \(sourceFailures.joined(separator: ", ")). Check the source setup and try again."
            }
        }
    }

    func retryCatalog(_ recording: DiscoveryRecording, lookup: ((String, String) async throws -> [SpotifyCatalogTrack])? = nil) {
        guard !isSearching, !isSyncing else { return }
        isSearching = true; catalogNotice = nil
        progress = "Checking Spotify: \(recording.artist.name) — \(recording.title)"
        task = Task {
            defer { isSearching = false; progress = ""; persist() }
            var updated: DiscoveryRecording
            do {
                let tracks: [SpotifyCatalogTrack]
                if let lookup { tracks = try await lookup(recording.artist.name, recording.title) }
                else { tracks = try await spotify.catalog(artist: recording.artist.name, title: recording.title) }
                guard !Task.isCancelled else { return }
                if let match = DiscoveryMatching.matchingTrack(tracks, artist: recording.artist, title: recording.title) {
                    updated = DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
                        availability: .found, catalogURI: match.uri)
                    catalogNotice = "Found on Spotify: \(recording.title)."
                } else {
                    updated = DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
                        availability: .noMatch, detail: "The check completed with no exact artist/title match. Alternate titles, versions, or regional availability can affect results.")
                    catalogNotice = "Check complete: no exact Spotify match for \(recording.title)."
                }
            } catch {
                updated = DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
                    availability: .unknown, detail: error.localizedDescription)
                catalogNotice = "Spotify check failed. Availability is still unknown."
            }
            if let index = recordings.firstIndex(where: { $0.id == recording.id }) { recordings[index] = updated }
        }
    }

    func refreshCatalog(lookup: ((String, String) async throws -> [SpotifyCatalogTrack])? = nil) {
        guard !isSearching, !isSyncing, !recordings.isEmpty else { return }
        let pending = recordings
        isSearching = true; catalogNotice = nil
        progress = "Refreshing Spotify checks…"
        task = Task {
            defer { isSearching = false; progress = ""; persist() }
            var checked = 0
            var found = 0
            for (index, recording) in pending.enumerated() {
                do {
                    try Task.checkCancellation()
                    progress = "Checking Spotify \(checked + 1)/\(pending.count): \(recording.artist.name) — \(recording.title)"
                    let tracks: [SpotifyCatalogTrack]
                    if let lookup { tracks = try await lookup(recording.artist.name, recording.title) }
                    else { tracks = try await spotify.catalog(artist: recording.artist.name, title: recording.title) }
                    try Task.checkCancellation()
                    let match = DiscoveryMatching.matchingTrack(tracks, artist: recording.artist, title: recording.title)
                    var updated = DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
                        availability: match == nil ? .noMatch : .found, catalogURI: match?.uri)
                    if match == nil { updated.detail = "No exact artist/title/version match in Spotify’s search results. Availability varies by region." }
                    recordings[index] = updated
                    checked += 1
                    if match != nil { found += 1 }
                    if checked < pending.count { try await Task.sleep(for: .milliseconds(350)) }
                } catch is CancellationError {
                    catalogNotice = "Spotify refresh stopped. Completed \(checked) of \(pending.count) checks."
                    return
                } catch {
                    if Task.isCancelled {
                        catalogNotice = "Spotify refresh stopped. Completed \(checked) of \(pending.count) checks."
                        return
                    }
                    recordings[index] = DiscoveryRecording(artist: recording.artist, title: recording.title, candidate: recording.candidate,
                        availability: .unknown, detail: error.localizedDescription)
                    // Authentication, rate-limit, and companion failures must not
                    // turn unchecked recordings into presumed catalog absences.
                    catalogNotice = "Spotify refresh stopped after \(checked) of \(pending.count) checks: \(error.localizedDescription)"
                    return
                }
            }
            catalogNotice = "Refreshed \(checked) Spotify checks: \(found) found, \(checked - found) without an exact match."
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
        if let data = try? JSONEncoder().encode(Snapshot(artists: artists, recordings: recordings, lastSynced: lastSynced,
                                                         hasSearched: hasSearched, warnings: warnings, error: error)) {
            defaults.set(data, forKey: "needle.discovery")
        }
    }
}
