import XCTest
@testable import NeedleDesktop

@MainActor
final class NeedleDesktopTests: XCTestCase {
    func testUpdatesAreDisabledWhenBundleHasNoFeed() {
        let updates = UpdateService(bundle: Bundle(for: type(of: self)))
        XCTAssertFalse(updates.isConfigured)
        XCTAssertFalse(updates.canCheckForUpdates)
    }

    func testUpdatesRequireTrustedFeedAndValidSigningKey() {
        let key = Data(repeating: 1, count: 32).base64EncodedString()
        XCTAssertTrue(UpdateService.isValidConfiguration(feedURL: "https://raw.githubusercontent.com/icebli/needle/main/appcast.xml", publicKey: key))
        XCTAssertFalse(UpdateService.isValidConfiguration(feedURL: "http://raw.githubusercontent.com/icebli/needle/main/appcast.xml", publicKey: key))
        XCTAssertFalse(UpdateService.isValidConfiguration(feedURL: "https://example.com/appcast.xml", publicKey: key))
        XCTAssertFalse(UpdateService.isValidConfiguration(feedURL: "https://raw.githubusercontent.com/icebli/needle/main/appcast.xml", publicKey: "invalid"))
    }

    func testSelectedSourceIsStableInTrackRequest() { let track = TrackRequest(artist: "A", title: "T", sourceURL: "https://example.com/selected"); XCTAssertEqual(track.sourceURL, "https://example.com/selected") }
    func testSpotifyPendingIsDistinctFromAdded() { let pending = TrackRequest(artist: "A", title: "T", spotifyStatus: .pending, stage: .spotifyPending, settingsSnapshot: NeedleSettings()); XCTAssertEqual(pending.spotifyStatus, .pending); XCTAssertNotEqual(pending.spotifyStatus, .added); XCTAssertEqual(pending.stage, .spotifyPending) }
    @MainActor
    func testSpotifyPlaylistLinksAreValidatedBeforeOpening() {
        XCTAssertNotNil(AppModel.spotifyPlaylistURL("spotify:playlist:abc123"))
        XCTAssertNotNil(AppModel.spotifyPlaylistURL("https://open.spotify.com/playlist/abc123?si=demo"))
        XCTAssertNil(AppModel.spotifyPlaylistURL("https://example.com/playlist/abc123"))
        XCTAssertNil(AppModel.spotifyPlaylistURL("spotify:track:abc123"))
    }
    func testSpotifyPlaylistDetailsSurviveHistoryRoundTrip() throws {
        let track = TrackRequest(artist: "A", title: "T", spotifyStatus: .added, spotifyJobID: "job", spotifyPlaylistName: "Private Needle", spotifyPlaylistURI: "spotify:playlist:abc", stage: .spotifyAdded)
        let decoded = try JSONDecoder().decode(TrackRequest.self, from: JSONEncoder().encode(track))
        XCTAssertEqual(decoded.spotifyPlaylistName, "Private Needle")
        XCTAssertEqual(decoded.spotifyPlaylistURI, "spotify:playlist:abc")
    }
    func testOlderHistoryWithoutPlaylistDetailsStillDecodes() throws {
        let track = TrackRequest(artist: "A", title: "T", spotifyStatus: .pending, spotifyJobID: "job", stage: .spotifyPending)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(track)) as? [String: Any])
        object.removeValue(forKey: "spotifyPlaylistName")
        object.removeValue(forKey: "spotifyPlaylistURI")
        object.removeValue(forKey: "discoveredFromFolder")
        let decoded = try JSONDecoder().decode(TrackRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.spotifyPlaylistName)
        XCTAssertNil(decoded.spotifyPlaylistURI)
        XCTAssertNil(decoded.discoveredFromFolder)
    }
    func testCLIParsesFinalJSONAfterHumanOutput() throws { let data = Data("progress: saving\n{\"ok\":true,\"tools\":[{\"name\":\"ffmpeg\",\"ok\":true}]}\n".utf8); let response = try NeedleCLIService.parseLastJSON(DoctorResponse.self, data: data); XCTAssertTrue(response.ok); XCTAssertEqual(response.tools.first?.name, "ffmpeg") }
    func testSearchCandidateDecodesRustThumbnailField() throws {
        let data = Data(#"{"ok":true,"request":{"artist":"Artist","title":"Title"},"metadata":null,"candidates":[{"candidate":{"provider":"youtube","id":"abc123","url":"https://youtube.com/watch?v=abc123","title":"Artist - Title","uploader":"Artist","duration_ms":200000,"thumbnail_url":"https://i.ytimg.com/vi/abc123/hqdefault.jpg"},"score":{"confidence":96,"status":"recommended","positives":[],"warnings":[],"rejects":[]}}]}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(SearchResponse.self, data: data)
        XCTAssertEqual(response.candidates.first?.candidate.thumbnailURL, "https://i.ytimg.com/vi/abc123/hqdefault.jpg")
    }
    func testLibraryScanDecodesTracksAndWarnings() throws {
        let data = Data(#"{"ok":true,"tracks":[{"path":"/tmp/Artist/Song.mp3","artist":"Artist","title":"Song","album":"Album","sourceUrl":"https://example.com/song","modifiedMs":1700000000000}],"warnings":["skipped backup"]}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(NeedleCLIService.LibraryScanResponse.self, data: data)
        XCTAssertEqual(response.tracks.first?.sourceURL, "https://example.com/song")
        XCTAssertEqual(response.warnings, ["skipped backup"])
    }

    func testLibraryScanFallbackUsesFolderAndFilenameMetadata() throws {
        let item = NeedleCLIService.LibraryScanTrack(path: "/tmp/Artist/Track.aiff", artist: nil, title: nil, album: nil, sourceURL: nil, modifiedMs: nil)
        let track = try XCTUnwrap(LibraryScanService.track(from: item))
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.title, "Track")
        XCTAssertEqual(track.album, "")
        XCTAssertEqual(track.settingsSnapshot?.format, "aiff")
        XCTAssertTrue(track.discoveredFromFolder == true)
    }

    func testLibraryMergeDeduplicatesPathAndPreservesDeliveryState() {
        let defaults = isolatedDefaults()
        let store = HistoryStore(defaults: defaults)
        let existing = TrackRequest(id: UUID(), artist: "Old", title: "Old title", sourceURL: "https://example.com/source", savedPath: "/tmp/Artist/Song.mp3", spotifyStatus: .added, spotifyJobID: "job", spotifyPlaylistName: "Needle", spotifyPlaylistURI: "spotify:playlist:abc", stage: .spotifyAdded)
        store.upsert(existing)
        let discovered = TrackRequest(artist: "Artist", title: "Song", album: "Album", savedPath: "/tmp/Artist/./Song.mp3", stage: .saved, settingsSnapshot: NeedleSettings(), date: .now, discoveredFromFolder: true)

        XCTAssertEqual(store.mergeLibraryTracks([discovered]), 0)
        XCTAssertEqual(store.tracks.count, 1)
        let merged = store.tracks[0]
        XCTAssertEqual(merged.id, existing.id)
        XCTAssertEqual(merged.artist, "Artist")
        XCTAssertEqual(merged.title, "Song")
        XCTAssertEqual(merged.spotifyStatus, .added)
        XCTAssertEqual(merged.spotifyPlaylistURI, "spotify:playlist:abc")
        XCTAssertFalse(merged.discoveredFromFolder == true)
        XCTAssertEqual(store.mergeLibraryTracks([discovered]), 0)
    }

    func testLibraryMergeDoesNotOverwriteInFlightMetadata() {
        let defaults = isolatedDefaults()
        let store = HistoryStore(defaults: defaults)
        let existing = TrackRequest(artist: "Requested", title: "Requested title", savedPath: "/tmp/in-flight.mp3", stage: .download)
        store.upsert(existing)
        let discovered = TrackRequest(artist: "Tagged", title: "Tagged title", savedPath: "/tmp/in-flight.mp3", stage: .saved, discoveredFromFolder: true)

        XCTAssertEqual(store.mergeLibraryTracks([discovered]), 0)
        XCTAssertEqual(store.tracks.first?.artist, "Requested")
        XCTAssertEqual(store.tracks.first?.stage, .download)
    }

    func testLibraryMergeAllowsAConfirmedEmptyAlbum() {
        let defaults = isolatedDefaults()
        let store = HistoryStore(defaults: defaults)
        let existing = TrackRequest(artist: "Artist", title: "Title", album: "Stale Album", savedPath: "/tmp/empty-album.mp3", stage: .saved)
        store.upsert(existing)
        let discovered = TrackRequest(artist: "Artist", title: "Title", album: "", savedPath: "/tmp/empty-album.mp3", stage: .saved, discoveredFromFolder: true)

        XCTAssertEqual(store.mergeLibraryTracks([discovered]), 0)
        XCTAssertEqual(store.tracks.first?.album, "")
    }
    func testPreviewUsesExactSourceAndDownloadsFullTrack() {
        let args = AudioPreviewService.previewArguments(sourceURL: "https://example.com/watch?v=abc", outputTemplate: "/tmp/excerpt.%(ext)s")
        XCTAssertEqual(args, ["--ignore-config", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio", "-x", "--audio-format", "mp3", "--audio-quality", "5", "-o", "/tmp/excerpt.%(ext)s", "https://example.com/watch?v=abc"])
        XCTAssertEqual(args.last, "https://example.com/watch?v=abc")
    }
    func testHistoryUpsertKeepsLatestTrackOnce() {
        let suite = "needle-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = HistoryStore(defaults: defaults)
        let id = UUID()
        store.upsert(TrackRequest(id: id, artist: "A", title: "T"))
        store.upsert(TrackRequest(id: id, artist: "A", title: "T2"))
        XCTAssertEqual(store.tracks.count, 1)
        XCTAssertEqual(store.tracks.first?.title, "T2")
    }

    func testLibraryInspectionDecodesEmbeddedArtworkMetadata() throws {
        let data = Data(#"{"ok":true,"track":{"path":"/tmp/song.mp3","tag_type":"ID3v2","artist":"Artist","title":"Song","album":null,"album_artist":null,"track":null,"disc":null,"date":null,"genre":null,"comment":null,"artwork":[{"index":0,"mime_type":"image/jpeg","bytes":1234,"extracted_path":"/tmp/artwork-0.jpeg"}]}}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(LibraryRepairService.InspectionResponse.self, data: data)
        XCTAssertEqual(response.track.artist, "Artist")
        XCTAssertEqual(response.track.artwork.first?.mimeType, "image/jpeg")
        XCTAssertEqual(response.track.artwork.first?.bytes, 1234)
    }

    func testLibraryRepairResponsePreservesBackupPath() throws {
        let data = Data(#"{"ok":true,"backup_path":"/tmp/.song.needle-backup-1.mp3","track":{"path":"/tmp/song.mp3","artist":"Artist","title":"Song","album":"Album","artwork":[]}}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(LibraryRepairService.RepairResponse.self, data: data)
        XCTAssertEqual(response.backupPath, "/tmp/.song.needle-backup-1.mp3")
        XCTAssertEqual(response.track.album, "Album")
    }

    func testLibrarySuggestionDecodesArtworkURLFromCLIJSON() throws {
        let data = Data(#"{"ok":true,"warning":"The release metadata may differ from this remix.","suggestion":{"artist":"Artist","title":"Song","album":"Album","artwork_url":"https://example.com/art.jpg"}}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(LibraryRepairService.SuggestionsResponse.self, data: data)
        XCTAssertEqual(response.suggestion?.artworkURL, "https://example.com/art.jpg")
        XCTAssertNotNil(response.warning)
    }

    @MainActor
    func testRejectedCandidateDoesNotCreateHistoryOrStartSave() {
        let defaults = isolatedDefaults()
        let model = AppModel(defaults: defaults)
        model.requestSnapshot = RequestSnapshot(artist: "Artist", title: "Title", album: "", sourceURL: "", settings: model.settings.value)
        let rejected = candidate(status: "rejected", url: "https://example.com/rejected")
        model.searchResults = [rejected]

        model.save(candidate: rejected, queueSpotify: false)

        XCTAssertTrue(model.history.tracks.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.message, "Choose an eligible recording from the current search.")
    }

    @MainActor
    func testCandidateFromAnotherSearchDoesNotCreateHistoryOrStartSave() {
        let defaults = isolatedDefaults()
        let model = AppModel(defaults: defaults)
        model.requestSnapshot = RequestSnapshot(artist: "Artist", title: "Title", album: "", sourceURL: "", settings: model.settings.value)
        let current = candidate(status: "accepted", url: "https://example.com/current")
        let foreign = candidate(status: "accepted", url: "https://example.com/foreign")
        model.searchResults = [current]

        model.save(candidate: foreign, queueSpotify: false)

        XCTAssertTrue(model.history.tracks.isEmpty)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.message, "Choose an eligible recording from the current search.")
    }

    @MainActor
    func testFlacTrackIsSavedWithoutAutomaticSpotifyDelivery() {
        let defaults = isolatedDefaults()
        let model = AppModel(defaults: defaults)
        var settings = model.settings.value
        settings.format = "flac"
        let track = TrackRequest(artist: "Artist", title: "Title", sourceURL: "https://example.com/track", savedPath: "/tmp/track.flac", stage: .saved, settingsSnapshot: settings)

        model.enqueue(track)

        XCTAssertEqual(model.history.tracks.count, 0)
        XCTAssertEqual(model.message, "Automatic Spotify delivery is available for MP3. This advanced output remains saved in your library.")
    }

    @MainActor
    func testExplicitSpotifyDeliveryPromotesImportedTrackToActivity() {
        let defaults = isolatedDefaults()
        let model = AppModel(defaults: defaults)
        var settings = model.settings.value
        settings.format = "mp3"
        let track = TrackRequest(artist: "Artist", title: "Title", sourceURL: "https://example.com/track", savedPath: "/tmp/track.mp3", stage: .saved, settingsSnapshot: settings, discoveredFromFolder: true)

        model.enqueue(track) { _, _ in .failure(CLIError.message("Test handoff")) }

        XCTAssertEqual(model.history.tracks.first?.discoveredFromFolder, false)
        XCTAssertEqual(model.history.tracks.first?.spotifyStatus, .pending)
    }

    func testHistoryStoreMarksEveryInFlightStageInterruptedOnReload() {
        let defaults = isolatedDefaults()
        let stages: [JobStage] = [.searching, .saving, .metadata, .download, .convert, .tag]
        let tracks = stages.map { TrackRequest(artist: "A", title: $0.rawValue, stage: $0) }
        defaults.set(try? JSONEncoder().encode(tracks), forKey: "needle.history")

        let reloaded = HistoryStore(defaults: defaults)

        XCTAssertEqual(reloaded.tracks.map(\.stage), Array(repeating: .interrupted, count: stages.count))
    }

    func testSettingsStorePersistsAdvancedSettingsInIsolatedDefaults() {
        let defaults = isolatedDefaults()
        let settings = SettingsStore(defaults: defaults)
        settings.value.provider = "yt-dlp"
        settings.value.format = "flac"
        settings.value.noMetadata = true
        settings.value.durationOverride = "123.45"
        settings.value.playlistName = "Private Needle"

        let reloaded = SettingsStore(defaults: defaults)

        XCTAssertEqual(reloaded.value.provider, "yt-dlp")
        XCTAssertEqual(reloaded.value.format, "flac")
        XCTAssertTrue(reloaded.value.noMetadata)
        XCTAssertEqual(reloaded.value.durationOverride, "123.45")
        XCTAssertEqual(reloaded.value.playlistName, "Private Needle")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "needle-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return defaults
    }

    private func candidate(status: String, url: String) -> CandidateResult {
        CandidateResult(candidate: Candidate(provider: "test", id: UUID().uuidString, url: url, title: "Title", uploader: nil, durationMs: nil, thumbnailURL: nil), score: Score(confidence: 0.9, status: status, positives: [], warnings: [], rejects: []))
    }
}
