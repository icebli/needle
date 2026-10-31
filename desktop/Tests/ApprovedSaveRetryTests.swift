import AppKit
import XCTest
@testable import NeedleDesktop

@MainActor
final class ApprovedSaveRetryTests: XCTestCase {
    func testFailedSavePersistsTheApprovalForRelaunch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-approved-save-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("needle")
        try """
        #!/bin/sh
        echo '{"event":"progress","stage":"download"}' >&2
        echo 'Error: download failed' >&2
        exit 1
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let suite = "needle-approved-save-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(defaults: defaults)
        var settings = NeedleSettings(); settings.cliPath = executable.path
        let candidate = CandidateResult(candidate: Candidate(provider: "test", id: "approved", url: "https://example.com/approved", title: "Source title", uploader: nil, durationMs: nil, thumbnailURL: nil), score: Score(confidence: 1, status: "recommended", positives: [], warnings: [], rejects: []))
        model.requestSnapshot = RequestSnapshot(artist: "Requested", title: "Requested title", album: "", sourceURL: "", settings: settings)
        model.searchResults = [candidate]
        let draft = MetadataDraft(artist: "Approved artist", title: "Approved title", album: "Approved album", albumArtist: "Album artist", artworkURL: "", source: "human", warnings: ["Reviewed"], sourceURL: candidate.candidate.url)
        model.save(candidate: candidate, queueSpotify: true, approved: draft)
        for _ in 0..<200 {
            if !model.isSaving { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(model.history.tracks.first?.stage, .failed)
        let persisted = try XCTUnwrap(defaults.data(forKey: "needle.history"))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: persisted) as? [[String: Any]])
        let approval = try XCTUnwrap(rows.first?["approvedSave"] as? [String: Any], "A failed save must retain the approved metadata and settings")
        XCTAssertEqual((approval["metadata"] as? [String: Any])?["title"] as? String, "Approved title")
        XCTAssertEqual(HistoryStore(defaults: defaults).tracks.first?.id, model.history.tracks.first?.id)
    }

    func testRetryAfterRelaunchRetainsEveryApprovalFieldAndLocalArtworkAndDeliversOnce() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let image = try imageData()
        let original = fixture.directory.appendingPathComponent("chosen.png")
        try image.write(to: original)
        var draft = fixture.draft
        draft.artworkURL = original.absoluteString
        let model = fixture.model()
        fixture.save(model, draft: draft, spotify: true)
        try await wait { !model.isSaving }
        let failed = try XCTUnwrap(model.history.tracks.first)
        XCTAssertTrue(model.canRetrySave(failed))
        XCTAssertEqual(failed.approvedSave?.metadata, draft)
        XCTAssertEqual(failed.approvedSave?.settings, fixture.settings)
        XCTAssertEqual(failed.approvedSave?.queueSpotify, true)
        let firstCommand = try fixture.command(attempt: 1)
        let commandCover = try XCTUnwrap(URL(string: firstCommand.metadata.artworkURL))
        XCTAssertEqual(try Data(contentsOf: commandCover), image)
        XCTAssertNotEqual(commandCover, original)
        try FileManager.default.removeItem(at: original)

        var deliveries: [UUID] = []
        let restored = fixture.model { deliveries.append($0.id) }
        restored.settings.value.format = "flac"
        restored.settings.value.playlistName = "Changed playlist"
        restored.requestSnapshot = nil
        restored.searchResults = []
        try fixture.allowSuccess()
        restored.retrySave(failed)
        restored.retrySave(failed)
        try await wait { !restored.isSaving }

        let saved = try XCTUnwrap(restored.history.tracks.first)
        XCTAssertEqual(saved.id, failed.id)
        XCTAssertEqual(restored.history.tracks.count, 1)
        XCTAssertEqual(saved.stage, .saved)
        XCTAssertEqual(saved.approvedSave?.metadata, draft)
        XCTAssertEqual(saved.settingsSnapshot, fixture.settings)
        XCTAssertEqual(deliveries, [failed.id])
        XCTAssertEqual(try fixture.attemptCount(), 2)
        let retried = try fixture.command(attempt: 2)
        XCTAssertEqual(retried.metadata, firstCommand.metadata)
        XCTAssertEqual(retried.arguments, firstCommand.arguments)
        XCTAssertEqual(Array(retried.arguments.prefix(3)), ["get", "Request artist", "Request title"])
        XCTAssertEqual(try Data(contentsOf: commandCover), image)
        XCTAssertFalse(restored.canRetrySave(failed))
        restored.retrySave(failed)
        XCTAssertEqual(deliveries.count, 1)
    }

    func testRemoteArtworkUsesCapturedBytesWhenOriginalLocationChanges() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let image = try imageData()
        let imageSource = ImageSource(image)
        let store = ApprovedArtworkStore(directory: fixture.artworkDirectory, load: { url in
            XCTAssertEqual(url.absoluteString, "https://example.com/original.png")
            return try await imageSource.read()
        })
        let model = fixture.model(store: store)
        var draft = fixture.draft
        draft.artworkURL = "https://example.com/original.png"
        fixture.save(model, draft: draft)
        try await wait { !model.isSaving }
        let failed = try XCTUnwrap(model.history.tracks.first)
        await imageSource.replace(with: Data("changed remote image".utf8))
        let restored = fixture.model(store: store)
        try fixture.allowSuccess()
        restored.retrySave(failed)
        try await wait { !restored.isSaving }
        let reads = await imageSource.readCount
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(restored.history.tracks.first?.approvedSave?.metadata.artworkURL, draft.artworkURL)
        let command = try fixture.command(attempt: 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(URL(string: command.metadata.artworkURL))), image)
    }

    func testQueueFailureCanRetryInActivityWithoutCreatingAnotherQueueJob() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        var item = ReviewItem(input: "Request artist — Request title", settings: fixture.settings)
        item.artist = "Request artist"; item.title = "Request title"; item.state = .ready
        item.response = SearchResponse(ok: true, request: nil, metadata: nil, candidates: [fixture.candidate], error: nil)
        model.reviewQueue.items = [item]
        model.reviewQueue.approve(fixture.candidate, itemID: item.id, spotify: true, approved: fixture.draft)
        try await wait { model.reviewQueue.activeDownloads == 0 }
        let failed = try XCTUnwrap(model.history.tracks.first)
        XCTAssertEqual(model.reviewQueue.items.first?.trackID, failed.id)
        XCTAssertEqual(failed.approvedSave?.metadata, fixture.draft)

        var delivered = 0
        let restored = fixture.model { _ in delivered += 1 }
        try fixture.allowSuccess()
        restored.retrySave(failed)
        XCTAssertEqual(restored.reviewQueue.items.first?.state, .downloading)
        XCTAssertEqual(restored.reviewQueue.activeDownloads, 1)
        restored.reviewQueue.approve(fixture.candidate, itemID: item.id, spotify: true, approved: fixture.draft)
        try await wait { !restored.isSaving }
        XCTAssertEqual(restored.history.tracks.count, 1)
        XCTAssertEqual(restored.reviewQueue.items.count, 1)
        XCTAssertEqual(restored.reviewQueue.items.first?.trackID, failed.id)
        XCTAssertEqual(restored.reviewQueue.items.first?.state, .saved)
        XCTAssertEqual(restored.reviewQueue.activeDownloads, 0)
        XCTAssertEqual(delivered, 1)
        XCTAssertEqual(try fixture.attemptCount(), 2)
        XCTAssertEqual(fixture.model().reviewQueue.items.first?.state, .saved)
    }

    func testEmptyAndSuppressedArtworkNeverLoadsOrFallsBack() async throws {
        for suppressed in [false, true] {
            let fixture = try SaveFixture()
            defer { fixture.remove() }
            let store = ApprovedArtworkStore(directory: fixture.artworkDirectory, load: { _ in
                XCTFail("Explicitly empty artwork must not load a cover")
                throw URLError(.badURL)
            })
            var draft = fixture.draft
            draft.artworkSuppressed = suppressed
            if suppressed { draft.artworkURL = "https://example.com/ignored.png" }
            let model = fixture.model(store: store)
            fixture.save(model, draft: draft)
            try await wait { !model.isSaving }
            XCTAssertEqual(try fixture.command(attempt: 1).metadata.artworkURL, "")
            let failed = try XCTUnwrap(model.history.tracks.first)
            model.retrySave(failed)
            try await wait { !model.isSaving }
            XCTAssertEqual(try fixture.command(attempt: 2).metadata.artworkURL, "")
            XCTAssertEqual(model.history.tracks.first?.approvedSave?.metadata, draft)
        }
    }

    func testArtworkCaptureFailureKeepsApprovalAndRetriesOnlyOriginalLocation() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let imageSource = ImageSource(nil)
        let store = ApprovedArtworkStore(directory: fixture.artworkDirectory, load: { url in
            XCTAssertEqual(url.absoluteString, "https://example.com/approved.png")
            return try await imageSource.read()
        })
        var draft = fixture.draft
        draft.artworkURL = "https://example.com/approved.png"
        let model = fixture.model(store: store)
        fixture.save(model, draft: draft)
        try await wait { !model.isSaving }
        let failed = try XCTUnwrap(model.history.tracks.first)
        XCTAssertEqual(failed.approvedSave?.metadata, draft)
        XCTAssertEqual(failed.approvedSave?.artwork, .pending)
        XCTAssertTrue(model.canRetrySave(failed))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("count").path))
        await imageSource.replace(with: try imageData())
        model.retrySave(failed)
        try await wait { !model.isSaving }
        XCTAssertEqual(try fixture.attemptCount(), 1)
        XCTAssertEqual(model.history.tracks.first?.approvedSave?.metadata, draft)
        XCTAssertNotEqual(model.history.tracks.first?.approvedSave?.artwork, .pending)
        XCTAssertTrue(model.canRetrySave(try XCTUnwrap(model.history.tracks.first)))
    }

    func testMissingOrCorruptCapturedArtworkNeverFetchesReplacementOrLaunchesAudio() async throws {
        for corrupt in [false, true] {
            let fixture = try SaveFixture()
            defer { fixture.remove() }
            let source = ImageSource(try imageData())
            let store = ApprovedArtworkStore(directory: fixture.artworkDirectory, load: { _ in try await source.read() })
            var draft = fixture.draft
            draft.artworkURL = "https://example.com/cover.png"
            let model = fixture.model(store: store)
            fixture.save(model, draft: draft)
            try await wait { !model.isSaving }
            let failed = try XCTUnwrap(model.history.tracks.first)
            let location = try XCTUnwrap(URL(string: fixture.command(attempt: 1).metadata.artworkURL))
            if corrupt { try Data("damaged".utf8).write(to: location) }
            else { try FileManager.default.removeItem(at: location) }
            model.retrySave(failed)
            try await wait { !model.isSaving }
            let latest = try XCTUnwrap(model.history.tracks.first)
            XCTAssertEqual(latest.approvedSave, failed.approvedSave)
            XCTAssertEqual(latest.saveRetrySafety, .requiresArtworkReview)
            XCTAssertFalse(model.canRetrySave(latest))
            XCTAssertEqual(try fixture.attemptCount(), 1)
            let reads = await source.readCount
            XCTAssertEqual(reads, 1)
            XCTAssertTrue(ActivityFailurePresentation(track: latest)?.recovery.contains("artwork") == true)
        }
    }

    func testUnsafeProcessOutcomesRequireLibraryReview() async throws {
        let cases = [
            "echo '{\"event\":\"progress\",\"stage\":\"save\"}' >&2\ndd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\\0' x >&2\nexit 1",
            "echo '{\"event\":\"progress\",\"stage\":\"download\"}' >&2\nprintf '%s' '{\"event\":\"progress\",\"stage\":\"save\"}' >&2\nexit 1",
            "echo '{\"event\":\"progress\",\"stage\":\"download\"}' >&2\necho '{\"ok\":false,\"saved_path\":\"/tmp/unconfirmed.mp3\"}'\nexit 1",
            "echo '{\"ok\":true,\"saved_path\":\"/tmp/wrong.mp3\",\"source_url\":\"https://example.com/wrong\"}'",
            "echo '{\"event\":\"progress\",\"stage\":\"download\"}' >&2\necho '{\"ok\":true}'",
            "echo malformed-json",
            "echo unknown-cli-failure >&2\nexit 1",
            "echo '{\"event\":\"progress\",\"stage\":\"download\"}' >&2\necho 'Your file was kept' >&2\nexit 1",
        ]
        for body in cases {
            let fixture = try SaveFixture(body: body)
            defer { fixture.remove() }
            let model = fixture.model()
            fixture.save(model)
            try await wait { !model.isSaving }
            let failed = try XCTUnwrap(model.history.tracks.first)
            XCTAssertEqual(failed.stage, .failed, body)
            XCTAssertEqual(failed.saveRetrySafety, .requiresReview, body)
            XCTAssertNil(failed.savedPath, "Unconfirmed output must never authorize Spotify delivery")
            XCTAssertFalse(model.canRetrySave(failed), body)
            XCTAssertTrue(ActivityFailurePresentation(track: failed)?.recovery.contains("Library") == true)
            XCTAssertFalse(fixture.model().canRetrySave(failed))
        }
    }

    func testSavedKeptInterruptedAndLegacyRowsCannotRetry() throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        var track = TrackRequest(artist: "Request artist", title: "Request title", sourceURL: fixture.candidate.candidate.url, stage: .failed)
        track.approvedSave = ApprovedSave(metadata: fixture.draft, settings: fixture.settings, queueSpotify: false)
        track.saveRetrySafety = .retryable
        model.history.upsert(track)
        XCTAssertTrue(model.canRetrySave(track))
        for detail in ["Your file was kept", "{\"event\":\"progress\",\"stage\":\"save\"}"] {
            track.errorDetail = detail
            model.history.upsert(track)
            XCTAssertFalse(model.canRetrySave(track))
        }
        track.errorDetail = nil
        track.savedPath = "/tmp/already-saved.mp3"
        model.history.upsert(track)
        XCTAssertFalse(model.canRetrySave(track))
        track.savedPath = nil
        track.stage = .download
        model.history.upsert(track)
        let restored = fixture.model()
        XCTAssertEqual(restored.history.tracks.first?.stage, .interrupted)
        XCTAssertFalse(restored.canRetrySave(track))
        XCTAssertEqual(restored.history.tracks.first?.approvedSave, track.approvedSave)

        track.stage = .failed; track.approvedSave = nil; track.saveRetrySafety = nil
        let legacy = try JSONDecoder().decode(TrackRequest.self, from: JSONEncoder().encode(track))
        XCTAssertNil(legacy.approvedSave)
        model.history.upsert(legacy)
        XCTAssertFalse(model.canRetrySave(legacy))
        XCTAssertTrue(ActivityFailurePresentation(track: legacy)?.recovery.contains("review") == true)
    }

    func testRetryReservesSourceAcrossRowsAndBlocksAnyExistingUncertainOrSavedAttempt() async throws {
        let fixture = try SaveFixture()
        defer { fixture.remove() }
        let model = fixture.model()
        fixture.save(model)
        try await wait { !model.isSaving }
        let failed = try XCTUnwrap(model.history.tracks.first)
        var other = TrackRequest(artist: failed.artist, title: failed.title, sourceURL: failed.sourceURL, stage: .failed)
        other.approvedSave = failed.approvedSave; other.saveRetrySafety = .retryable
        for state in [JobStage.saved, .interrupted, .failed] {
            other.stage = state
            other.savedPath = state == .saved ? "/tmp/kept.mp3" : nil
            other.saveRetrySafety = .requiresReview
            model.history.upsert(other)
            XCTAssertFalse(model.canRetrySave(failed))
        }
        other.stage = .failed; other.savedPath = nil; other.saveRetrySafety = .retryable
        model.history.upsert(other)
        try fixture.allowSuccess()
        model.retrySave(failed)
        XCTAssertFalse(model.canRetrySave(other))
        model.retrySave(other)
        try await wait { !model.isSaving }
        XCTAssertEqual(try fixture.attemptCount(), 2)
        XCTAssertFalse(model.canRetrySave(other))
    }

    func testCancelDuringArtworkCapturePreventsLaterAudioLaunchForDirectAndQueueSaves() async throws {
        for queued in [false, true] {
            let fixture = try SaveFixture()
            defer { fixture.remove() }
            let gate = ArtworkGate(image: try imageData())
            let store = ApprovedArtworkStore(directory: fixture.artworkDirectory, load: { _ in await gate.read() })
            let model = fixture.model(store: store)
            var draft = fixture.draft
            draft.artworkURL = "https://example.com/cover.png"
            var queueID: UUID?
            if queued {
                var item = ReviewItem(input: "Request", settings: fixture.settings)
                item.artist = "Request artist"; item.title = "Request title"; item.state = .ready
                item.response = SearchResponse(ok: true, request: nil, metadata: nil, candidates: [fixture.candidate], error: nil)
                queueID = item.id
                model.reviewQueue.items = [item]
                model.reviewQueue.approve(fixture.candidate, itemID: item.id, spotify: false, approved: draft)
            } else { fixture.save(model, draft: draft) }
            for _ in 0..<200 {
                if await gate.started { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            if let queueID { model.reviewQueue.cancel(queueID) }
            else { model.cancelCurrentOperation() }
            try await Task.sleep(for: .milliseconds(20))
            await gate.release()
            try await wait { !model.isSaving && model.reviewQueue.activeDownloads == 0 }
            XCTAssertEqual(model.history.tracks.first?.stage, .cancelled)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("count").path))
            XCTAssertEqual(model.history.tracks.first?.approvedSave?.metadata, draft)
        }
    }

    private func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The save did not finish")
        throw NSError(domain: "ApprovedSaveRetryTests", code: 1)
    }
}

@MainActor
private final class SaveFixture {
    let directory: URL
    let suite = "needle-save-retry-\(UUID())"
    let defaults: UserDefaults
    let candidate = CandidateResult(candidate: Candidate(provider: "test", id: "approved", url: "https://example.com/approved", title: "Original source", uploader: nil, durationMs: nil, thumbnailURL: "https://example.com/unapproved.png"), score: Score(confidence: 1, status: "recommended", positives: [], warnings: [], rejects: []))
    var settings: NeedleSettings
    var artworkDirectory: URL { directory.appendingPathComponent("approved-art") }
    var draft: MetadataDraft {
        MetadataDraft(artist: "Approved artist", title: "Approved title", album: "Approved album", albumArtist: "Approved album artist", artworkURL: "", source: "human review", warnings: ["Retain this provenance"], sourceURL: candidate.candidate.url)
    }

    init(body: String? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-save-retry-\(UUID())")
        defaults = UserDefaults(suiteName: suite)!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("needle")
        var settings = NeedleSettings()
        settings.cliPath = executable.path
        settings.albumHint = "Original album hint"
        settings.durationOverride = "123.5"
        settings.noMetadata = true
        settings.playlistName = "Original playlist"
        self.settings = settings
        let normal = """
        echo '{"event":"progress","stage":"download"}' >&2
        if [ ! -f '\(directory.path)/succeed' ]; then echo 'Error: download failed' >&2; exit 1; fi
        sleep 0.1
        echo '{"event":"progress","stage":"save"}' >&2
        echo '{"ok":true,"saved_path":"\(directory.path)/saved.mp3","artist":"Approved artist","title":"Approved title","album":"Approved album","source_url":"https://example.com/approved"}'
        """
        let script = """
        #!/bin/sh
        set -eu
        count=0
        if [ -f '\(directory.path)/count' ]; then count=$(cat '\(directory.path)/count'); fi
        count=$((count + 1))
        printf '%s' "$count" > '\(directory.path)/count'
        printf '%s\\n' "$@" > "\(directory.path)/args$count"
        \(body ?? normal)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func model(store: ApprovedArtworkStore? = nil, handoff: ((TrackRequest) -> Void)? = nil) -> AppModel {
        AppModel(defaults: defaults, approvedArtworkStore: store ?? ApprovedArtworkStore(directory: artworkDirectory), savedTrackHandoff: handoff ?? { _ in XCTFail("Unexpected Spotify handoff") })
    }

    func save(_ model: AppModel, draft: MetadataDraft? = nil, spotify: Bool = false) {
        model.requestSnapshot = RequestSnapshot(artist: "Request artist", title: "Request title", album: settings.albumHint, sourceURL: "", settings: settings)
        model.searchResults = [candidate]
        model.save(candidate: candidate, queueSpotify: spotify, approved: draft ?? self.draft)
    }

    func allowSuccess() throws { try Data().write(to: directory.appendingPathComponent("succeed")) }
    func attemptCount() throws -> Int { Int(try String(contentsOf: directory.appendingPathComponent("count"), encoding: .utf8))! }

    func command(attempt: Int) throws -> (arguments: [String], metadata: MetadataDraft) {
        var arguments = try String(contentsOf: directory.appendingPathComponent("args\(attempt)"), encoding: .utf8).components(separatedBy: .newlines)
        if arguments.last == "" { arguments.removeLast() }
        let index = try XCTUnwrap(arguments.firstIndex(of: "--approved-tags"))
        let metadata = try JSONDecoder().decode(MetadataDraft.self, from: Data(arguments[index + 1].utf8))
        arguments.removeSubrange(index...(index + 1))
        return (arguments, metadata)
    }

    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor ImageSource {
    var readCount = 0
    private var data: Data?
    init(_ data: Data?) { self.data = data }
    func replace(with data: Data) { self.data = data }
    func read() throws -> Data {
        readCount += 1
        guard let data else { throw URLError(.notConnectedToInternet) }
        return data
    }
}

private actor ArtworkGate {
    let image: Data
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    init(image: Data) { self.image = image }
    func read() async -> Data {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return image
    }
    func release() { continuation?.resume(); continuation = nil }
}
