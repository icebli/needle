import Foundation
import Observation
import AppKit

@MainActor @Observable
final class AppModel {
    var destination: Destination = .addMusic
    var settings: SettingsStore
    var history: HistoryStore
    var searchResults: [CandidateResult] = []
    var metadata: Metadata?
    var requestSnapshot: RequestSnapshot?
    var isSearching = false
    var isSaving: Bool { !saveServices.isEmpty }
    private var saveServices: [UUID: NeedleCLIService] = [:]
    var reviewQueue: ReviewQueue
    var discovery: DiscoveryStore
    var bookmarks: BookmarkStore
    var artworkBackfill: ArtworkBackfillService
    var isCancelling = false
    var isCheckingTools = false
    var tools: DoctorResponse?
    var setupMessage: String?
    var message: String?
    var selectedCandidateID: String?
    var pollingJobIDs: Set<UUID> = []
    private var reconcilingTrackIDs: Set<UUID> = []
    private var spotifyReconcileRevisions: [UUID: Int] = [:]
    var isScanningLibrary = false
    var libraryScanError: String?
    var libraryScanWarnings: [String] = []
    var libraryImportedCount = 0
    let cli = NeedleCLIService()
    let libraryScan = LibraryScanService()
    let spotify = SpotifyHostService()
    var isBusy: Bool { isSearching || isSaving }

    init(defaults: UserDefaults = .standard) {
        settings = SettingsStore(defaults: defaults)
        let savedHistory = HistoryStore(defaults: defaults)
        history = savedHistory
        reviewQueue = ReviewQueue(defaults: defaults, history: savedHistory)
        discovery = DiscoveryStore(defaults: defaults)
        bookmarks = BookmarkStore(defaults: defaults)
        artworkBackfill = ArtworkBackfillService(defaults: defaults)
        reviewQueue.onSaved = { [weak self] track, spotify in if spotify { self?.enqueue(track) } }
        artworkBackfill.onFileUpdated = { [weak self] updated, previous in
            self?.reconcileSpotifyMetadata(updated, previous: previous)
        }
        recoverSpotifyJobs()
        if history.tracks.contains(where: { $0.spotifyJobID != nil && $0.savedPath.map(FileManager.default.fileExists(atPath:)) == true }) {
            scanLibrary()
        }
    }

    static func mediaURL(_ text: String) -> URL? {
        guard let url = URL(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil else { return nil }
        return url
    }

    static func spotifyPlaylistURL(_ text: String) -> URL? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("spotify:playlist:"), value.count > "spotify:playlist:".count {
            return URL(string: value)
        }
        guard let url = URL(string: value),
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "open.spotify.com" else { return nil }
        let components = url.path.split(separator: "/")
        guard components.count == 2, components[0] == "playlist", !components[1].isEmpty else { return nil }
        return url
    }

    func openSpotifyPlaylist(_ track: TrackRequest) {
        guard let uri = track.spotifyPlaylistURI, let url = Self.spotifyPlaylistURL(uri) else {
            message = "Spotify did not provide a usable playlist link yet."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func checkTools() {
        guard !isBusy, !isCheckingTools else { return }
        isCheckingTools = true
        setupMessage = nil
        let snapshot = settings.value
        Task {
            defer { isCheckingTools = false }
            switch await cli.doctor(settings: snapshot) {
            case .success(let response): tools = response
            case .failure(let error): setupMessage = error.localizedDescription
            }
        }
    }

    func clearSearch() {
        guard !isSearching else { return }
        searchResults = []
        metadata = nil
        requestSnapshot = nil
        selectedCandidateID = nil
    }

    func scanLibrary() {
        guard !isScanningLibrary else { return }
        isScanningLibrary = true
        libraryScanError = nil
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/needle", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let snapshot = settings.value
        Task {
            let result = await libraryScan.scan(root: root, settings: snapshot, history: history)
            isScanningLibrary = false
            switch result {
            case .success(let summary):
                libraryImportedCount = summary.imported
                libraryScanWarnings = summary.warnings
                for update in summary.spotifyUpdates { reconcileSpotifyMetadata(update.current, previous: update.previous) }
                refreshArtwork()
            case .failure(let error):
                libraryScanError = error.localizedDescription
                libraryScanWarnings = []
            }
        }
    }

    func refreshArtwork(retry: Bool = false) {
        Task {
            await artworkBackfill.run(bookmarks: bookmarks, history: history, settings: settings.value, retry: retry)
        }
    }

    func cancelCurrentOperation() {
        guard isBusy, !isCancelling else { return }
        isCancelling = true
        Task {
            if isSearching { await cli.cancel() }
            else if let service = saveServices.values.first { await service.cancel() }
        }
    }

    func search(artist: String, title: String, album: String = "", sourceURL: String?) {
        guard !isSearching, !isCheckingTools else { return }
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = (sourceURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !title.isEmpty else {
            message = "Enter the artist and song title so Needle can check the recording."
            return
        }
        guard source.isEmpty || Self.mediaURL(source) != nil else {
            message = "Use an http or https source link."
            return
        }
        var snapshotSettings = settings.value
        if !album.isEmpty { snapshotSettings.albumHint = album }
        let snapshot = RequestSnapshot(artist: artist, title: title, album: snapshotSettings.albumHint,
                                       sourceURL: source, settings: snapshotSettings)
        clearSearch()
        requestSnapshot = snapshot
        isSearching = true
        message = nil
        Task {
            let result = await cli.search(artist: artist, title: title, sourceURL: source, settings: snapshot.settings)
            isSearching = false
            isCancelling = false
            switch result {
            case .success(let response):
                searchResults = response.candidates
                metadata = response.metadata
                if response.candidates.isEmpty { message = "No recordings found. Try another title or paste a source link." }
            case .failure(let error):
                message = error is CancellationError ? "Search cancelled." : error.localizedDescription
            }
        }
    }

    func prepareMetadata(candidate: CandidateResult, queueSpotify: Bool) async -> MetadataDraft? {
        guard let snapshot = requestSnapshot, !isSearching, !isCheckingTools,
              candidate.score.status != "rejected",
              searchResults.contains(where: { $0.id == candidate.id && $0.candidate.url == candidate.candidate.url }) else { return nil }
        let service = NeedleCLIService()
        let result = await service.prepareMetadata(artist: snapshot.artist, title: snapshot.title, candidate: candidate.candidate, settings: snapshot.settings)
        guard !Task.isCancelled, requestSnapshot == snapshot else { return nil }
        switch result {
        case .success(let draft): return draft
        case .failure(let error): message = error.localizedDescription; return nil
        }
    }

    func save(candidate: CandidateResult, queueSpotify: Bool, approved: MetadataDraft? = nil) {
        guard !isSearching, !isCheckingTools else { return }
        guard candidate.score.status != "rejected", let snapshot = requestSnapshot,
              searchResults.contains(where: { $0.id == candidate.id && $0.candidate.url == candidate.candidate.url }),
              Self.mediaURL(candidate.candidate.url) != nil,
              approved?.sourceURL == candidate.candidate.url,
              selectedCandidateID != candidate.id else {
            message = "Choose an eligible recording from the current search."
            return
        }
        let album = snapshot.album
        let track = TrackRequest(artist: snapshot.artist, title: snapshot.title, album: album,
                                 sourceURL: candidate.candidate.url, stage: .metadata,
                                 settingsSnapshot: snapshot.settings)
        history.upsert(track)
        let downloadService = NeedleCLIService()
        saveServices[track.id] = downloadService
        selectedCandidateID = candidate.id
        destination = .activity
        message = nil
        Task { [self] in
            let result = await downloadService.get(track: track, settings: snapshot.settings, approved: approved, onProgress: { [weak self] stage in
                Task { @MainActor in
                    guard let self, self.saveServices[track.id] != nil, let stage = JobStage.progress(stage),
                          var current = self.history.tracks.first(where: { $0.id == track.id }),
                          current.savedPath == nil else { return }
                    current.stage = stage
                    self.history.upsert(current)
                }
            })
            saveServices.removeValue(forKey: track.id)
            isCancelling = false
            switch result {
            case .success(var saved):
                saved.stage = .saved
                history.upsert(saved)
                if queueSpotify && snapshot.settings.format == "mp3" { enqueue(saved) }
            case .failure(let error):
                var failed = history.tracks.first(where: { $0.id == track.id }) ?? track
                failed.stage = error is CancellationError ? .cancelled : .failed
                failed.errorDetail = error is CancellationError ? "The download was cancelled. No existing music was removed." : error.localizedDescription
                history.upsert(failed)
            }
        }
    }

    func enqueue(_ track: TrackRequest, handoff: ((TrackRequest, String) async -> Result<String, Error>)? = nil) {
        guard track.savedPath != nil, track.spotifyStatus != .added, !pollingJobIDs.contains(track.id) else { return }
        if track.spotifyReconcileNeeded == true { reconcileSpotifyMetadata(track); return }
        if track.spotifyJobID != nil {
            Task { await poll(track, resume: true) }
            return
        }
        guard track.settingsSnapshot?.format ?? "mp3" == "mp3" else {
            message = "Automatic Spotify delivery is available for MP3. This advanced output remains saved in your library."
            return
        }
        var pending = track
        // A user explicitly requested Spotify delivery for an imported file;
        // promote it into normal Activity tracking from this point onward.
        pending.discoveredFromFolder = false
        pending.spotifyStatus = .pending
        pending.spotifyPlaylistName = track.spotifyPlaylistName ?? track.settingsSnapshot?.playlistName ?? settings.value.playlistName
        pending.spotifyPlaylistURI = nil
        pending.stage = .spotifyPending
        pending.errorDetail = nil
        history.upsert(pending)
        pollingJobIDs.insert(track.id)
        let playlist = track.settingsSnapshot?.playlistName ?? settings.value.playlistName
        Task {
            let result: Result<String, Error>
            if let handoff { result = await handoff(pending, playlist) }
            else { result = await spotify.enqueue(track: pending, playlistName: playlist) }
            switch result {
            case .success(let id):
                pending.spotifyJobID = id
                history.upsert(pending)
                pollingJobIDs.remove(track.id)
                await poll(pending)
            case .failure(let error):
                pending.spotifyStatus = .failed
                pending.stage = .saved
                pending.errorDetail = "Your file is saved. Spotify delivery needs attention: \(error.localizedDescription)"
                history.upsert(pending)
                pollingJobIDs.remove(track.id)
            }
        }
    }

    func reconcileSpotifyMetadata(_ updated: TrackRequest, previous: TrackRequest? = nil,
                                  handoff: ((TrackRequest, TrackRequest) async -> Result<String, Error>)? = nil) {
        guard updated.spotifyJobID != nil, let path = updated.savedPath,
              FileManager.default.fileExists(atPath: path), URL(fileURLWithPath: path).pathExtension.lowercased() == "mp3" else { return }
        spotifyReconcileRevisions[updated.id, default: 0] += 1
        var current = history.tracks.first(where: { $0.id == updated.id }) ?? updated
        current.spotifyReconcileNeeded = true
        current.spotifyStatus = .pending
        current.stage = .spotifyPending
        current.errorDetail = "Checking Spotify for this file's current metadata. The playlist entry is preserved until its replacement is confirmed."
        history.upsert(current)
        guard reconcilingTrackIDs.insert(current.id).inserted else { return }
        Task {
            defer { reconcilingTrackIDs.remove(current.id) }
            var baseline = previous ?? current
            while let desired = history.tracks.first(where: { $0.id == current.id }) {
                let requestedRevision = spotifyReconcileRevisions[current.id]
                let result = if let handoff { await handoff(desired, baseline) } else { await spotify.reconcile(track: desired, previous: baseline) }
                guard var latest = history.tracks.first(where: { $0.id == current.id }), latest.spotifyJobID == desired.spotifyJobID else { return }
                switch result {
                case .success(let id):
                    latest.spotifyJobID = id
                    latest.spotifyStatus = .pending
                    latest.spotifyReconcileNeeded = true
                    latest.stage = .spotifyPending
                    history.upsert(latest)
                    if spotifyReconcileRevisions[current.id] != requestedRevision
                        || SpotifyMetadataSnapshot(track: latest) != SpotifyMetadataSnapshot(track: desired) {
                        baseline = desired
                        continue
                    }
                    // An older poll may still be awaiting the predecessor. It
                    // will stop at its job-ID guard and this poll owns the new ID.
                    let pending = latest
                    Task {
                        while pollingJobIDs.contains(pending.id) { try? await Task.sleep(for: .milliseconds(100)) }
                        await poll(pending, resume: true)
                    }
                    return
                case .failure(let error):
                    if spotifyReconcileRevisions[current.id] != requestedRevision { baseline = desired; continue }
                    latest.spotifyStatus = .failed
                    latest.stage = .saved
                    latest.errorDetail = "The file is updated. Spotify metadata repair needs attention: \(error.localizedDescription)"
                    history.upsert(latest)
                    return
                }
            }
        }
    }

    func poll(_ initial: TrackRequest, resume: Bool = false,
              delays: [Int] = [0, 2, 4, 8, 15, 30, 30, 30, 30, 30, 30, 30],
              statusCheck: ((String) async -> Result<HostStatus, Error>)? = nil) async {
        guard let id = initial.spotifyJobID, !pollingJobIDs.contains(initial.id) else { return }
        pollingJobIDs.insert(initial.id)
        defer { pollingJobIDs.remove(initial.id) }
        var track = initial
        if resume { _ = await spotify.status(jobID: id, resume: true) }
        // Local-file indexing can take several minutes. Keep the same job alive
        // long enough for Spotify to surface it, while still leaving a clear
        // retry state instead of polling forever.
        for delay in delays {
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            let response = if let statusCheck { await statusCheck(id) } else { await spotify.status(jobID: id) }
            guard let latest = history.tracks.first(where: { $0.id == initial.id }), latest.spotifyJobID == id else { return }
            track = latest
            switch response {
            case .success(let status):
                if status.status == "added", status.playlistUri != nil, status.addedUri != nil {
                    track.spotifyStatus = .added
                    track.spotifyPlaylistURI = status.playlistUri
                    track.stage = .spotifyAdded
                    track.errorDetail = status.detail
                    track.spotifyMetadataSnapshot = status.track
                    let delivered = status.track
                    let matchesCurrent = delivered.map { $0.name == track.title && $0.artist == track.artist && ($0.album ?? "") == track.album } ?? (track.spotifyReconcileNeeded != true)
                    track.spotifyReconcileNeeded = !matchesCurrent
                    history.upsert(track)
                    if !matchesCurrent { reconcileSpotifyMetadata(track) }
                    return
                }
                if status.status == "pending" {
                    let playlist = track.spotifyPlaylistName ?? track.settingsSnapshot?.playlistName ?? "Needle"
                    track.errorDetail = status.detail ?? "Local-file indexing or companion startup can take a few minutes. Needle will keep checking the \"\(playlist)\" playlist."
                    history.upsert(track)
                }
                if status.status == "unknown" {
                    track.spotifyStatus = .unknown
                    track.stage = .saved
                    if track.spotifyReconcileNeeded != true { track.spotifyJobID = nil }
                    track.errorDetail = track.spotifyReconcileNeeded == true
                        ? "Spotify metadata repair could not find its original receipt. Your file is saved; Check Spotify retries the same repair."
                        : "Spotify did not confirm this job. Your file is safe; you can retry delivery."
                    history.upsert(track)
                    return
                }
            case .failure(let error):
                track.errorDetail = "Waiting for Spotify. \(error.localizedDescription)"
            }
        }
        guard let latest = history.tracks.first(where: { $0.id == initial.id }), latest.spotifyJobID == id else { return }
        track = latest
        track.spotifyStatus = .pending
        track.stage = .spotifyPending
        if track.errorDetail == nil || track.errorDetail?.contains("Local-file indexing or companion startup") == true {
            track.errorDetail = "Open Spotify and check Local Files. Use Check Spotify to resume this same delivery job."
        }
        history.upsert(track)
    }

    private func recoverSpotifyJobs() {
        for track in history.tracks where track.spotifyStatus == .pending && track.spotifyJobID != nil {
            Task { await poll(track, resume: true) }
        }
        for track in history.tracks where track.spotifyStatus == .added && track.spotifyPlaylistURI == nil && track.spotifyJobID != nil {
            Task { await hydrateSpotifyDestination(track) }
        }
    }

    private func hydrateSpotifyDestination(_ initial: TrackRequest) async {
        guard let id = initial.spotifyJobID else { return }
        guard case .success(let status) = await spotify.status(jobID: id),
              status.status == "added",
              let playlistURI = status.playlistUri else { return }
        guard var track = history.tracks.first(where: { $0.id == initial.id }), track.spotifyJobID == id else { return }
        track.spotifyPlaylistURI = playlistURI
        track.spotifyMetadataSnapshot = status.track
        history.upsert(track)
    }
}

struct RequestSnapshot: Equatable {
    let artist: String
    let title: String
    let album: String
    let sourceURL: String
    let settings: NeedleSettings
}
