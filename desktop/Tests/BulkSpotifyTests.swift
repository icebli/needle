import XCTest
@testable import NeedleDesktop

@MainActor
final class BulkSpotifyTests: XCTestCase {
    func testBulkSpotifySummaryQueuesOnlyEligibleTracks() throws {
        let suite = "needle-bulk-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let eligible = folder.appendingPathComponent("eligible.mp3")
        let alreadyAdded = folder.appendingPathComponent("added.mp3")
        let waiting = folder.appendingPathComponent("waiting.mp3")
        let flac = folder.appendingPathComponent("advanced.flac")
        try Data().write(to: eligible)
        try Data().write(to: alreadyAdded)
        try Data().write(to: waiting)
        try Data().write(to: flac)

        var mp3 = NeedleSettings()
        mp3.format = "mp3"
        var advanced = mp3
        advanced.format = "flac"
        model.history.upsert(TrackRequest(artist: "A", title: "Eligible", savedPath: eligible.path, stage: .saved, settingsSnapshot: mp3))
        model.history.upsert(TrackRequest(artist: "A", title: "Added", savedPath: alreadyAdded.path, spotifyStatus: .added, stage: .spotifyAdded, settingsSnapshot: mp3))
        model.history.upsert(TrackRequest(artist: "A", title: "Waiting", savedPath: waiting.path, spotifyStatus: .pending, spotifyJobID: "job", stage: .spotifyPending, settingsSnapshot: mp3))
        model.history.upsert(TrackRequest(artist: "A", title: "Advanced", savedPath: flac.path, stage: .saved, settingsSnapshot: advanced))
        model.history.upsert(TrackRequest(artist: "A", title: "Missing", savedPath: folder.appendingPathComponent("gone.mp3").path, stage: .saved, settingsSnapshot: mp3))

        var handoffs: [TrackRequest] = []
        let summary = model.enqueueAllLibraryTracksToSpotify { handoffs.append($0) }

        XCTAssertEqual(summary, BulkSpotifySummary(queued: 1, alreadyAdded: 1, inFlight: 1, missing: 1, unsupported: 1))
        XCTAssertEqual(model.message, "Queued 1 recording for Spotify. (1 already added, 1 already waiting, 1 missing, 1 non-MP3 skipped)")
        XCTAssertEqual(handoffs.map(\.title), ["Eligible"])
    }

    func testBulkSpotifyIsIdempotentWhileFirstHandoffIsInFlight() throws {
        let suite = "needle-bulk-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("needle-bulk-\(UUID().uuidString).mp3")
        try Data().write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        model.history.upsert(TrackRequest(artist: "A", title: "Track", savedPath: path.path, stage: .saved, settingsSnapshot: NeedleSettings()))

        var handoffs = 0
        let stub: (TrackRequest) -> Void = { track in
            handoffs += 1
            model.pollingJobIDs.insert(track.id)
        }
        let first = model.enqueueAllLibraryTracksToSpotify(enqueueTrack: stub)
        let second = model.enqueueAllLibraryTracksToSpotify(enqueueTrack: stub)

        XCTAssertEqual(first.queued, 1)
        XCTAssertEqual(second.queued, 0)
        XCTAssertEqual(second.inFlight, 1)
        XCTAssertEqual(handoffs, 1)
    }
}
