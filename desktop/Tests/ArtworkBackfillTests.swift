import XCTest
@testable import NeedleDesktop

@MainActor
final class ArtworkBackfillTests: XCTestCase {
    private let cover = ArtworkReference(url: "https://coverartarchive.org/release/edition/front", provider: "cover_art_archive", releaseId: "edition", releaseGroupId: "group")

    private func candidate(_ id: String = "source") -> Candidate {
        Candidate(provider: "youtube", id: id, url: "https://youtube.com/watch?v=\(id)", title: "Upload", uploader: "Uploader", durationMs: 180_000, thumbnailURL: nil)
    }

    func testBackfillPersistsOnlyCoverAndPreservesExactBookmarkedSource() async throws {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Song (Remix)", album: "The Album", candidate: candidate())
        let original = try XCTUnwrap(bookmarks.items.first)
        let service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            XCTAssertEqual(request.album, "The Album"); XCTAssertEqual(request.title, "Song (Remix)")
            XCTAssertNil(request.path)
            XCTAssertEqual(request.sourceTitle, original.candidate.title)
            XCTAssertEqual(request.sourceDurationMs, original.candidate.durationMs)
            XCTAssertEqual(request.sourceURL, original.candidate.url)
            XCTAssertTrue(request.arguments.contains("--source-duration-ms"))
            XCTAssertEqual(Array(request.arguments.suffix(2)), ["--source-url", original.candidate.url])
            return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "matched", error: nil)
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        let restored = try XCTUnwrap(BookmarkStore(defaults: defaults).items.first)
        XCTAssertEqual(restored.artwork, cover); XCTAssertEqual(restored.candidate.url, original.candidate.url)
        XCTAssertEqual(restored.date, original.date); XCTAssertEqual(restored.album, original.album)
        XCTAssertEqual(service.filled, 1)
    }

    func testLateResultCannotResurrectRemovedOrReplacedBookmark() async {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Song", candidate: candidate())
        var calls = 0
        let service = ArtworkBackfillService(defaults: defaults, lookup: { _, _ in
            calls += 1
            bookmarks.remove(bookmarks.items[0])
            bookmarks.toggle(artist: "Different Artist", title: "Different Song", candidate: self.candidate(), artwork: self.cover)
            return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "matched", error: nil)
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 1); XCTAssertEqual(service.filled, 0)
        XCTAssertEqual(bookmarks.items.first?.artist, "Different Artist")
    }

    func testResolverUpgradeRetriesOldMissesAndKeepsNewCooldown() async throws {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Song", candidate: candidate())
        var calls = 0
        let lookup: (ArtworkBackfillRequest, NeedleSettings) async throws -> ArtworkBackfillResponse = { _, _ in
            calls += 1
            return ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil)
        }
        await ArtworkBackfillService(defaults: defaults, lookup: lookup)
            .run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        let priorLedger = try XCTUnwrap(defaults.data(forKey: "needle.artworkBackfill.v3"))
        defaults.set(priorLedger, forKey: "needle.artworkBackfill.v2")
        defaults.removeObject(forKey: "needle.artworkBackfill.v3")
        await ArtworkBackfillService(defaults: defaults, lookup: lookup)
            .run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 2)
        await ArtworkBackfillService(defaults: defaults, lookup: lookup)
            .run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 2)
    }

    func testNoMatchCooldownSurvivesRelaunchAndExplicitRetryWorks() async {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Song", candidate: candidate())
        var calls = 0
        let lookup: (ArtworkBackfillRequest, NeedleSettings) async throws -> ArtworkBackfillResponse = { _, _ in
            calls += 1
            return ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil)
        }
        let service = ArtworkBackfillService(defaults: defaults, lookup: lookup)
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        let relaunched = ArtworkBackfillService(defaults: defaults, lookup: lookup)
        await relaunched.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 1)
        await relaunched.run(bookmarks: bookmarks, history: history, settings: NeedleSettings(), retry: true)
        XCTAssertEqual(calls, 2)
    }

    func testExistingCoversAreNeverLookedUpAndStopDoesNotApplyLateResults() async {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Covered", candidate: candidate("covered"), artwork: cover)
        bookmarks.toggle(artist: "Artist", title: "Missing", candidate: candidate())
        var service: ArtworkBackfillService!
        var calls = 0
        service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            calls += 1; XCTAssertEqual(request.title, "Missing"); service.stop()
            return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "matched", error: nil)
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 1); XCTAssertNil(bookmarks.items.first?.artwork)
        XCTAssertTrue(service.isPaused); XCTAssertFalse(service.isRunning)
    }

    func testSavedFileBackfillKeepsLatestDeliveryStateAndRefreshesArtwork() async throws {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        let original = TrackRequest(artist: "Artist", title: "Song", album: "Album", sourceURL: "https://example.com/source", savedPath: file.path, stage: .saved)
        history.upsert(original)
        let service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            XCTAssertEqual(request.path, file.path)
            history.tracks[0].spotifyStatus = .added
            return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "filled", error: nil)
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(history.tracks[0].spotifyStatus, .added)
        XCTAssertEqual(history.tracks[0].sourceURL, original.sourceURL)
        XCTAssertEqual(history.tracks[0].album, original.album)
        XCTAssertNotNil(history.tracks[0].artworkUpdatedAt)
        XCTAssertEqual(service.filled, 1)
    }

    func testCLIResponseDecodesPinnedReleaseIdentity() throws {
        let response = try NeedleCLIService.parseLastJSON(ArtworkBackfillResponse.self, data: Data(#"{"ok":true,"status":"matched","artwork":{"url":"https://example.com/cover","provider":"cover_art_archive","release_id":"edition","release_group_id":"group"}}"#.utf8))
        XCTAssertEqual(response.artwork?.releaseId, "edition")
    }

    func testMalformedSidecarSourceDoesNotCrashAutomaticBackfill() async throws {
        let suite = "NeedleMalformedBackfill.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        let sidecar = file.deletingPathExtension().appendingPathExtension("json")
        try Data([1]).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: sidecar)
        }
        let history = HistoryStore(defaults: defaults)
        history.upsert(TrackRequest(artist: "Artist", title: "Song", savedPath: file.path, stage: .saved))
        var calls = 0
        let service = ArtworkBackfillService(defaults: defaults, lookup: { _, _ in
            calls += 1
            return ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil)
        })
        let malformedSources: [Any] = ["malformed", 42, NSNull(), ["malformed"]]
        for source in malformedSources {
            try JSONSerialization.data(withJSONObject: ["selected_source": source]).write(to: sidecar)
            await service.run(bookmarks: BookmarkStore(defaults: defaults), history: history, settings: NeedleSettings(), retry: true)
        }
        XCTAssertEqual(calls, 4)
        XCTAssertNil(history.tracks.first?.artworkUpdatedAt)
    }

    func testExplicitlyClearedCoverStaysExcludedAfterRelaunch() async throws {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data([1]).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let history = HistoryStore(defaults: defaults)
        var track = TrackRequest(artist: "Artist", title: "Song", savedPath: file.path, stage: .saved)
        track.artworkSuppressed = true
        history.upsert(track)
        let service = ArtworkBackfillService(defaults: defaults, lookup: { _, _ in
            XCTFail("An explicitly cleared cover must never be backfilled")
            return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "filled", error: nil)
        })
        await service.run(bookmarks: BookmarkStore(defaults: defaults), history: HistoryStore(defaults: defaults), settings: NeedleSettings(), retry: true)
        XCTAssertEqual(service.checked, 0)
        XCTAssertEqual(HistoryStore(defaults: defaults).tracks[0].artworkSuppressed, true)
    }

    func testArtworkReasonsDecodeWithoutBreakingOlderCLIResponses() throws {
        let old = try NeedleCLIService.parseLastJSON(ArtworkBackfillResponse.self,
            data: Data(#"{"ok":true,"status":"unmatched","artwork":null}"#.utf8))
        XCTAssertNil(old.reason)
        let current = try NeedleCLIService.parseLastJSON(ArtworkBackfillResponse.self,
            data: Data(#"{"ok":true,"status":"unmatched","reason":"no_verified_catalog_cover","lookup_album":"Album","artwork":null}"#.utf8))
        XCTAssertEqual(current.reason, "no_verified_catalog_cover")
    }

    func testMissingCoverReasonsStaySeparateFromProviderFailures() async {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        let reasons: [String?] = [
            "missing_independent_source_evidence", "source_identity_or_filename_conflict",
            "unverified_album_variant_requires_metadata_review", "no_verified_catalog_cover", nil, "future_reason"
        ]
        for index in reasons.indices {
            bookmarks.toggle(artist: "Artist", title: String(index), candidate: candidate(String(index)))
        }
        let service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil,
                reason: reasons[Int(request.title)!])
        })
        service.onFileUpdated = { _, _ in XCTFail("Missing covers never change saved files") }
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(service.checked, 6)
        XCTAssertEqual(service.unavailable, 6)
        XCTAssertEqual(service.needsMetadataReview, 2)
        XCTAssertEqual(service.missingSourceEvidence, 1)
        XCTAssertEqual(service.catalogMisses, 1)
        XCTAssertEqual(service.temporaryFailures, 0)
        XCTAssertEqual(service.unspecifiedMisses, 2)
        XCTAssertEqual(service.filled, 0)
    }

    func testTemporaryFailureCountsResetWhenTheNextCheckSucceeds() async {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bookmarks = BookmarkStore(defaults: defaults); let history = HistoryStore(defaults: defaults)
        bookmarks.toggle(artist: "Artist", title: "Missing", candidate: candidate("missing"))
        bookmarks.toggle(artist: "Artist", title: "Failure", candidate: candidate("failure"))
        var recovered = false
        let service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            if recovered { return ArtworkBackfillResponse(ok: true, artwork: self.cover, status: "matched", error: nil) }
            if request.title == "Failure" { throw CLIError.message("Provider unavailable") }
            return ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil,
                reason: "no_verified_catalog_cover")
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(service.unavailable, 2)
        XCTAssertEqual(service.temporaryFailures, 1)
        XCTAssertEqual(service.catalogMisses, 1)
        XCTAssertEqual(service.unspecifiedMisses, 0)
        recovered = true
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings(), retry: true)
        XCTAssertEqual(service.unavailable, 0)
        XCTAssertEqual(service.temporaryFailures, 0)
        XCTAssertEqual(service.catalogMisses, 0)
        XCTAssertEqual(service.filled, 2)
    }

    func testSourceArgumentsCarryThumbnailAndPositiveDuration() {
        var request = ArtworkBackfillRequest(artist: "Wiz Khalifa", title: "MAAN! Weedmix", album: "", path: nil,
            sourceTitle: "Wiz Khalifa - MAAN! Weedmix", sourceDurationMs: 251_000,
            sourceURL: "https://youtu.be/abcdefghijk", sourceThumbnailURL: "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
        XCTAssertEqual(request.arguments, ["artwork", "--artist", "Wiz Khalifa", "--title", "MAAN! Weedmix", "--album", "", "--json",
            "--source-title", "Wiz Khalifa - MAAN! Weedmix", "--source-duration-ms", "251000",
            "--source-url", "https://youtu.be/abcdefghijk", "--source-thumbnail-url", "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"])
        request.sourceDurationMs = 0
        XCTAssertFalse(request.arguments.contains("--source-duration-ms"))
    }

    func testSavedSourceEvidenceChangesRetryWithoutWaitingForCooldown() async throws {
        let suite = "NeedleBackfill.\(UUID())"; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("Song.mp3")
        let sidecar = directory.appendingPathComponent("Song.json")
        try Data([1]).write(to: file)
        let writeSource = { (duration: Int) in
            try Data("{\"selected_source\":{\"title\":\"Artist - Song\",\"duration_ms\":\(duration),\"url\":\"https://youtu.be/abcdefghijk\",\"provider\":\"youtube\",\"id\":\"abcdefghijk\"}}".utf8).write(to: sidecar)
        }
        try writeSource(180_000)
        let originalDate = try XCTUnwrap(try sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let history = HistoryStore(defaults: defaults)
        history.upsert(TrackRequest(artist: "Artist", title: "Song", sourceURL: "https://youtu.be/abcdefghijk", savedPath: file.path, stage: .saved))
        let bookmarks = BookmarkStore(defaults: defaults)
        var calls = 0
        let service = ArtworkBackfillService(defaults: defaults, lookup: { request, _ in
            calls += 1
            XCTAssertEqual(request.sourceURL, history.tracks[0].sourceURL)
            return ArtworkBackfillResponse(ok: true, artwork: nil, status: "unmatched", error: nil)
        })
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 1)
        try writeSource(181_000)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: sidecar.path)
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 2, "Source evidence itself must change the key even at identical file size and mtime")
        history.tracks[0].sourceURL = "https://youtu.be/other-video"
        await service.run(bookmarks: bookmarks, history: history, settings: NeedleSettings())
        XCTAssertEqual(calls, 3)
    }
}
