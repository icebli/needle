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
    private(set) var run: Run?
    static let candidatesPerArtist = 45

    enum RunPhase: String, Codable {
        case sources, catalog, completed, cancelled, interrupted
    }

    struct Run: Codable {
        var phase: RunPhase
        let selectedArtistIDs: [String]
        var artistsAttempted = 0
        var artistsCompleted = 0
        var sourceFailures = 0
        var sourceNotices = 0
        var catalogChecked = 0
        var catalogFailure: String?
    }

    var runSummary: String? {
        guard let run else {
            return hasSearched ? "Previous search coverage is unknown. Find recordings to search your selection." : nil
        }
        let total = run.selectedArtistIDs.count
        var parts: [String] = []
        switch run.phase {
        case .sources:
            parts.append("Searching artists \(run.artistsAttempted) of \(total).")
        case .catalog, .completed:
            if run.artistsCompleted == total {
                parts.append("Searched all \(total) selected artists.")
            } else {
                parts.append("Completed \(run.artistsCompleted) of \(total) selected artist searches.")
            }
        case .cancelled:
            parts.append("Search stopped. Completed \(run.artistsCompleted) of \(total) artist searches.")
        case .interrupted:
            parts.append("Search interrupted. Completed \(run.artistsCompleted) of \(total) artist searches.")
        }
        if run.sourceFailures > 0 { parts.append("\(run.sourceFailures) source searches failed.") }
        if run.sourceNotices > 0 { parts.append("\(run.sourceNotices) source search notices; coverage may be incomplete.") }
        parts.append("\(recordings.count) recordings found.")
        let unknown = recordings.filter { $0.availability == .unknown }.count
        if run.catalogFailure != nil && unknown > 0 { parts.append("Spotify checks paused. Open Spotify, then use Refresh all.") }
        parts.append("Spotify resolved \(recordings.count - unknown) of \(recordings.count); \(unknown) unconfirmed.")
        return parts.joined(separator: " ")
    }

    var runNeedsAttention: Bool {
        guard let run else { return hasSearched }
        return run.phase == .cancelled || run.phase == .interrupted || run.sourceFailures > 0 || run.sourceNotices > 0
            || (run.catalogFailure != nil && recordings.contains { $0.availability == .unknown })
    }
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
        let selectedArtistIDs: Set<String>?
        let run: Run?
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "needle.discovery"), let value = try? JSONDecoder().decode(Snapshot.self, from: data) {
            artists = value.artists; recordings = value.recordings; lastSynced = value.lastSynced
            hasSearched = value.hasSearched ?? !value.recordings.isEmpty
            warnings = value.warnings ?? []
            error = value.error
            selectedArtistIDs = value.selectedArtistIDs ?? Set(artists.prefix(3).map(\.id))
            run = value.run
            if run?.phase == .sources || run?.phase == .catalog {
                run?.phase = .interrupted
                persist()
            }
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

    func find(settings: NeedleSettings, library: [TrackRequest], sourceLookup: (@MainActor (String) async throws -> [Candidate])? = nil,
              catalogLookup: (@MainActor (String, String) async throws -> [SpotifyCatalogTrack])? = nil) {
        guard !isSearching, !isSyncing else { return }
        let selection = artists.filter { selectedArtistIDs.contains($0.id) }
        guard !selection.isEmpty else { error = "Select artists to search."; return }
        isSearching = true; hasSearched = true; error = nil; catalogNotice = nil; warnings = []; recordings = []
        run = Run(phase: .sources, selectedArtistIDs: selection.map(\.id))
        persist()
        task = Task {
            defer {
                let stopped = Task.isCancelled || run?.phase == .cancelled
                run?.phase = stopped ? .cancelled : .completed
                recordings.sort { ($0.candidate.viewCount ?? 0) > ($1.candidate.viewCount ?? 0) }
                isSearching = false; progress = ""; persist()
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await self.collectSources(selection: selection, settings: settings, library: library, lookup: sourceLookup)
                }
                group.addTask {
                    await self.checkCatalog(lookup: catalogLookup)
                }
            }
        }
    }

    private func collectSources(selection: [SpotifyArtist], settings: NeedleSettings, library: [TrackRequest],
                                lookup: (@MainActor (String) async throws -> [Candidate])?) async {
        defer {
            if run?.phase == .sources { run?.phase = .catalog }
            persist()
        }
        var seen = Set<String>()
        var sourceFailures: [String] = []
        for (artistIndex, artist) in selection.enumerated() {
            guard !Task.isCancelled else { return }
            run?.artistsAttempted += 1
            persist()
            progress = "Artist \(artistIndex + 1)/\(selection.count): finding popular uploads for \(artist.name)…"
            struct Sources: Decodable { let ok: Bool; let candidates: [Candidate]; let warnings: [String]? }
            do {
                let response: Sources
                if let lookup {
                    response = Sources(ok: true, candidates: try await lookup(artist.name), warnings: nil)
                } else {
                    let data = try await cli.runJSONCommand(["discover", artist.name, "--json", "--source", settings.provider], settings: settings)
                    response = try NeedleCLIService.parseLastJSON(Sources.self, data: data)
                }
                try Task.checkCancellation()
                guard response.ok else { throw CLIError.message("Source search failed for \(artist.name).") }
                warnings.append(contentsOf: response.warnings ?? [])
                run?.sourceNotices += response.warnings?.count ?? 0
                var accepted = 0
                for candidate in response.candidates {
                    guard !Task.isCancelled else { return }
                    guard accepted < Self.candidatesPerArtist else { break }
                    let title = DiscoveryMatching.title(candidate.title, artist: artist.name)
                    let key = artist.id + ":" + DiscoveryMatching.normalized(title)
                    guard !title.isEmpty, AppModel.mediaURL(candidate.url) != nil,
                          !seen.contains(key),
                          !DiscoveryMatching.isInLibrary(candidate: candidate, artist: artist.name, title: title, tracks: library) else { continue }
                    seen.insert(key)
                    recordings.append(DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .unknown))
                    accepted += 1
                }
                run?.artistsCompleted += 1
            } catch is CancellationError { run?.phase = .cancelled; return }
            catch {
                guard !Task.isCancelled else { return }
                warnings.append("\(artist.name): \(error.localizedDescription)")
                sourceFailures.append(artist.name)
                run?.sourceFailures += 1
                self.error = "Couldn’t search \(sourceFailures.joined(separator: ", ")). Check the source setup and try again."
            }
            persist()
        }
    }

    private func checkCatalog(lookup: (@MainActor (String, String) async throws -> [SpotifyCatalogTrack])?) async {
        var index = 0
        var lastCheckpoint = ContinuousClock.now
        defer { persist() }
        while !Task.isCancelled {
            guard index < recordings.count else {
                guard run?.phase == .sources else { return }
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { return }
                continue
            }
            let recording = recordings[index]
            do {
                try Task.checkCancellation()
                if run?.phase == .catalog {
                    progress = "Checking Spotify \(index + 1)/\(recordings.count): \(recording.artist.name) — \(recording.title)"
                }
                let tracks: [SpotifyCatalogTrack]
                if let lookup { tracks = try await lookup(recording.artist.name, recording.title) }
                else { tracks = try await spotify.catalog(artist: recording.artist.name, title: recording.title) }
                try Task.checkCancellation()
                recordings[index] = DiscoveryMatching.assessingCatalog(recording, tracks: tracks)
                run?.catalogChecked += 1
                if index == 0 || (index + 1).isMultiple(of: 25) || lastCheckpoint.duration(to: .now) >= .seconds(2) {
                    persist()
                    lastCheckpoint = .now
                }
                index += 1
                if lookup == nil { try await Task.sleep(for: .milliseconds(350)) }
            } catch is CancellationError { run?.phase = .cancelled; return }
            catch {
                guard !Task.isCancelled else { return }
                recordings[index].detail = error.localizedDescription
                run?.catalogFailure = error.localizedDescription
                warnings.append("Spotify catalog checks paused: \(error.localizedDescription)")
                persist()
                return
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
                updated = DiscoveryMatching.assessingCatalog(recording, tracks: tracks)
                switch updated.availability {
                case .found: catalogNotice = "Found on Spotify: \(recording.title)."
                case .noMatch: catalogNotice = "Check complete: no exact Spotify match for \(recording.title)."
                case .unknown: catalogNotice = updated.detail
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
            var unconfirmed = 0
            for (index, recording) in pending.enumerated() {
                do {
                    try Task.checkCancellation()
                    progress = "Checking Spotify \(checked + 1)/\(pending.count): \(recording.artist.name) — \(recording.title)"
                    let tracks: [SpotifyCatalogTrack]
                    if let lookup { tracks = try await lookup(recording.artist.name, recording.title) }
                    else { tracks = try await spotify.catalog(artist: recording.artist.name, title: recording.title) }
                    try Task.checkCancellation()
                    let updated = DiscoveryMatching.assessingCatalog(recording, tracks: tracks)
                    recordings[index] = updated
                    checked += 1
                    if updated.availability == .found { found += 1 }
                    if updated.availability == .unknown { unconfirmed += 1 }
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
            let reviewNotice = unconfirmed > 0 ? " \(unconfirmed) need review." : ""
            catalogNotice = "Refreshed \(checked) Spotify checks: \(found) found, \(checked - found - unconfirmed) without an exact match." + reviewNotice
        }
    }

    func cancel() {
        task?.cancel()
        if run?.phase == .sources || run?.phase == .catalog {
            run?.phase = .cancelled
            persist()
        }
        Task { await cli.cancel() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Snapshot(artists: artists, recordings: recordings, lastSynced: lastSynced,
                                                         hasSearched: hasSearched, warnings: warnings, error: error,
                                                         selectedArtistIDs: selectedArtistIDs, run: run)) {
            defaults.set(data, forKey: "needle.discovery")
        }
    }
}
