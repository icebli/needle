import XCTest
@testable import NeedleDesktop

@MainActor
final class SpotifyReconciliationTests: XCTestCase {
    func testPollingMergesDeliveryIntoLatestMetadataInsteadOfCapturedSnapshot() async {
        let defaults = UserDefaults(suiteName: "spotify-poll-\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        let original = TrackRequest(artist: "Old artist", title: "Old title", savedPath: "/tmp/test.mp3", spotifyStatus: .pending, spotifyJobID: "job", stage: .spotifyPending)
        model.history.upsert(original)
        await model.poll(original, delays: [0], statusCheck: { _ in
            var edited = original
            edited.artist = "Current artist"
            edited.title = "Current title"
            edited.album = "Current album"
            model.history.upsert(edited)
            return .success(HostStatus(ok: true, status: "added", playlistUri: "spotify:playlist:p", addedUri: "spotify:local:new"))
        })
        XCTAssertEqual(model.history.tracks.first?.title, "Current title")
        XCTAssertEqual(model.history.tracks.first?.artist, "Current artist")
        XCTAssertEqual(model.history.tracks.first?.album, "Current album")
        XCTAssertEqual(model.history.tracks.first?.spotifyStatus, .added)
    }

    func testPredecessorPollCannotOverwriteNewRepairJobOrMetadata() async {
        let model = AppModel(defaults: UserDefaults(suiteName: "spotify-stale-\(UUID().uuidString)")!)
        let original = TrackRequest(artist: "Artist", title: "A", savedPath: "/tmp/test.mp3", spotifyStatus: .pending, spotifyJobID: "A", stage: .spotifyPending)
        model.history.upsert(original)
        await model.poll(original, delays: [0], statusCheck: { _ in
            var latest = original
            latest.title = "B"
            latest.spotifyJobID = "replacement-B"
            latest.spotifyReconcileNeeded = true
            model.history.upsert(latest)
            return .success(HostStatus(ok: true, status: "added", playlistUri: "spotify:playlist:p", addedUri: "spotify:local:A"))
        })
        XCTAssertEqual(model.history.tracks.first?.title, "B")
        XCTAssertEqual(model.history.tracks.first?.spotifyJobID, "replacement-B")
        XCTAssertEqual(model.history.tracks.first?.spotifyStatus, .pending)
        XCTAssertEqual(model.history.tracks.first?.spotifyReconcileNeeded, true)
    }

    func testConfirmedSnapshotAndArtworkLimitationSurviveHistoryRestart() async throws {
        let defaults = UserDefaults(suiteName: "spotify-snapshot-\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        let original = TrackRequest(artist: "Artist", title: "Title", album: "Album", savedPath: "/tmp/test.mp3", spotifyStatus: .pending, spotifyJobID: "job", stage: .spotifyPending)
        model.history.upsert(original)
        let snapshot = SpotifyMetadataSnapshot(track: original)
        await model.poll(original, delays: [0], statusCheck: { _ in
            .success(HostStatus(ok: true, status: "added", playlistUri: "spotify:playlist:p", addedUri: "spotify:local:new", detail: "Spotify artwork refresh is unconfirmed.", track: snapshot))
        })
        let reloaded = HistoryStore(defaults: defaults).tracks.first
        XCTAssertEqual(reloaded?.spotifyMetadataSnapshot, snapshot)
        XCTAssertEqual(reloaded?.errorDetail, "Spotify artwork refresh is unconfirmed.")
        XCTAssertEqual(reloaded?.spotifyReconcileNeeded, false)
    }
    func testSecondArtworkChangeDuringHandoffIsCoalescedEvenWhenTagsAreIdentical() async throws {
        let model = AppModel(defaults: UserDefaults(suiteName: "spotify-artwork-race-\(UUID().uuidString)")!)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-race-\(UUID().uuidString).mp3")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let original = TrackRequest(artist: "Artist", title: "Same tags", savedPath: file.path, spotifyStatus: .added, spotifyJobID: "original", stage: .spotifyAdded)
        model.history.upsert(original)
        var handoffs = 0
        model.reconcileSpotifyMetadata(original, handoff: { desired, _ in
            handoffs += 1
            if handoffs == 1 {
                var artworkChanged = desired
                artworkChanged.artworkUpdatedAt = Date()
                model.history.upsert(artworkChanged)
                model.reconcileSpotifyMetadata(artworkChanged)
                return .success("repair")
            }
            return .failure(CLIError.message("Stop after observing the second handoff"))
        })
        for _ in 0..<100 where handoffs < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(handoffs, 2)
        XCTAssertEqual(model.history.tracks.first?.spotifyJobID, "repair")
        XCTAssertEqual(model.history.tracks.first?.spotifyReconcileNeeded, true)
    }

    func testOnlyActualArtworkWritesNotifyTheCurrentFileAssociation() async throws {
        let defaults = UserDefaults(suiteName: "spotify-artwork-callback-\(UUID().uuidString)")!
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("spotify-callback-\(UUID().uuidString).mp3")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let history = HistoryStore(defaults: defaults)
        let original = TrackRequest(artist: "Artist", title: "Title", savedPath: file.path, spotifyStatus: .added, spotifyJobID: "exact-job", stage: .spotifyAdded)
        history.upsert(original)
        var notifications: [TrackRequest] = []
        let service = ArtworkBackfillService(defaults: defaults, lookup: { _, _ in
            ArtworkBackfillResponse(ok: true, artwork: nil, status: "filled", error: nil)
        })
        service.onFileUpdated = { current, previous in
            XCTAssertEqual(previous.id, original.id)
            XCTAssertEqual(current.spotifyJobID, "exact-job")
            XCTAssertNotNil(current.artworkUpdatedAt)
            notifications.append(current)
        }
        await service.run(bookmarks: BookmarkStore(defaults: defaults), history: history, settings: NeedleSettings())
        XCTAssertEqual(notifications.count, 1)
        let existing = ArtworkBackfillService(defaults: defaults, lookup: { _, _ in
            ArtworkBackfillResponse(ok: true, artwork: nil, status: "existing", error: nil)
        })
        existing.onFileUpdated = { _, _ in XCTFail("Existing artwork does not change the audio file") }
        await existing.run(bookmarks: BookmarkStore(defaults: defaults), history: history, settings: NeedleSettings(), retry: true)
    }

}
