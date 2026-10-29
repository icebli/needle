import XCTest
@testable import NeedleDesktop

@MainActor
final class MetadataPreparationLifetimeTests: XCTestCase {
    func testAppModelDoesNotPublishFailureForReplacedRequest() async throws {
        let fixture = try makeFailingPrepareFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "needle-metadata-lifetime-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = AppModel(defaults: defaults)
        var settings = model.settings.value
        settings.cliPath = fixture.executable.path
        let candidate = candidate(url: "https://example.com/source", status: "recommended")
        model.requestSnapshot = RequestSnapshot(artist: "Old artist", title: "Old title", album: "", sourceURL: "", settings: settings)
        model.searchResults = [candidate]

        let pending = Task { await model.prepareMetadata(candidate: candidate, queueSpotify: false) }
        try await waitForFile(fixture.started)
        model.requestSnapshot = RequestSnapshot(artist: "New artist", title: "New title", album: "", sourceURL: "", settings: settings)
        try Data("release".utf8).write(to: fixture.release)
        let result = await pending.value

        XCTAssertNil(result)
        XCTAssertNil(model.message)
    }

    func testQueueDoesNotReplaceNewItemDetailWithOldFailure() async throws {
        let fixture = try makeFailingPrepareFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "needle-queue-metadata-lifetime-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        var settings = NeedleSettings()
        settings.cliPath = fixture.executable.path
        var item = ReviewItem(input: "Old artist — Old title", settings: settings)
        item.artist = "Old artist"
        item.title = "Old title"
        item.state = .ready
        let candidate = candidate(url: "https://example.com/source", status: "recommended")
        item.response = SearchResponse(ok: true, request: RequestEcho(artist: item.artist, title: item.title), metadata: nil, candidates: [candidate], error: nil)
        queue.items = [item]
        queue.selectedID = item.id

        let pending = Task { await queue.prepareMetadata(candidate, itemID: item.id) }
        try await waitForFile(fixture.started)
        var replacement = try XCTUnwrap(queue.items.first)
        replacement.artist = "New artist"
        replacement.title = "New title"
        replacement.detail = "New request is ready"
        queue.update(replacement)
        try Data("release".utf8).write(to: fixture.release)
        let result = await pending.value

        XCTAssertNil(result)
        XCTAssertEqual(queue.items.first?.detail, "New request is ready")
    }

    private struct Fixture {
        let directory: URL
        let executable: URL
        let started: URL
        let release: URL
    }

    private func makeFailingPrepareFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-metadata-lifetime-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("needle-fixture")
        let started = directory.appendingPathComponent("started")
        let release = directory.appendingPathComponent("release")
        let script = """
        #!/bin/sh
        if [ "$1" = "prepare" ]; then
          touch '\(started.path)'
          while [ ! -f '\(release.path)' ]; do sleep 0.01; done
          echo 'stale preparation failed' >&2
          exit 1
        fi
        exit 1
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return Fixture(directory: directory, executable: executable, started: started, release: release)
    }

    private func candidate(url: String, status: String) -> CandidateResult {
        CandidateResult(candidate: Candidate(provider: "test", id: "same", url: url, title: "Song", uploader: "Artist", durationMs: 180_000, thumbnailURL: nil),
                        score: Score(confidence: 0.9, status: status, positives: [], warnings: [], rejects: []))
    }

    private func waitForFile(_ url: URL) async throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("fixture did not start")
    }
}
