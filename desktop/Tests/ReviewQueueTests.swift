import XCTest
@testable import NeedleDesktop

@MainActor
final class ReviewQueueTests: XCTestCase {
    func testParsesListsWithoutGuessingArtistFromUnstructuredText() {
        let values = ReviewItem.parse("Doechii — Nissan Altima (Whethan Remix)\nhttps://example.com/track\nNot structured\nA - B - Remix\n", settings: NeedleSettings())
        XCTAssertEqual(values.count, 4)
        XCTAssertEqual(values[0].artist, "Doechii")
        XCTAssertEqual(values[0].title, "Nissan Altima (Whethan Remix)")
        XCTAssertEqual(values[1].sourceURL, "https://example.com/track")
        XCTAssertEqual(values[2].state, .needsInput)
        XCTAssertEqual(values[3].title, "B - Remix")
    }

    func testRestartPreservesCandidatesButDoesNotAutoDownloadApprovedItems() throws {
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite!) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        var item = ReviewItem(input: "A — T", settings: NeedleSettings())
        item.artist = "A"; item.title = "T"; item.state = .approved
        queue.items = [item]
        let restored = ReviewQueue(defaults: defaults, history: history)
        XCTAssertEqual(restored.items[0].state, .interrupted)
        XCTAssertEqual(restored.activeDownloads, 0)
        XCTAssertTrue(history.tracks.isEmpty)
    }

    func testReviewAndSearchContinueDuringApprovedBackgroundDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-queue-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("needle-fixture")
        let script = #"""
        #!/bin/sh
        case "$1" in
        search)
          printf '%s\n' '{"ok":true,"candidates":[{"candidate":{"provider":"test","id":"exact","url":"https://example.com/exact","title":"A - T"},"score":{"status":"recommended","positives":[],"warnings":[],"rejects":[]}}]}'
          ;;
        get)
          sleep 1
          printf '%s\n' '{"ok":true,"saved_path":"/tmp/needle-queue-test.mp3","artist":"A","title":"T","album":"","source_url":"https://example.com/exact"}'
          ;;
        esac
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let defaults = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite!) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        var settings = NeedleSettings(); settings.cliPath = executable.path
        queue.add("A — T", settings: settings)
        try await wait { queue.items.first?.state == .ready }
        XCTAssertTrue(history.tracks.isEmpty, "Searching must never save audio")
        let first = try XCTUnwrap(queue.items.first)
        let candidate = try XCTUnwrap(first.response?.candidates.first)
        let foreign = CandidateResult(candidate: Candidate(provider: "test", id: "foreign", url: "https://example.com/foreign", title: "Foreign", uploader: nil, durationMs: nil, thumbnailURL: nil), score: candidate.score)
        queue.approve(foreign, itemID: first.id, spotify: false)
        XCTAssertEqual(queue.items[0].state, .ready)
        XCTAssertTrue(history.tracks.isEmpty)
        queue.approve(candidate, itemID: first.id, spotify: false)
        XCTAssertEqual(queue.activeDownloads, 1)
        queue.add("Second — Recording", settings: settings)
        try await wait { queue.items.last?.state == .ready }
        XCTAssertEqual(queue.items[0].state, .downloading)
        XCTAssertEqual(queue.activeDownloads, 1)
        // A duplicate approval cannot start a second download.
        queue.approve(candidate, itemID: first.id, spotify: false)
        XCTAssertEqual(history.tracks.count, 1)
        try await wait { queue.items[0].state == .saved }
        XCTAssertEqual(history.tracks.first?.savedPath, "/tmp/needle-queue-test.mp3")
        XCTAssertEqual(queue.items[1].state, .ready)
        let restored = ReviewQueue(defaults: defaults, history: history)
        XCTAssertEqual(restored.items[0].state, .saved)
        XCTAssertEqual(restored.items[1].response?.candidates.first?.candidate.url, "https://example.com/exact")
    }

    private var defaultsSuite: String?
    private func isolatedDefaults() -> UserDefaults {
        let name = "needle-queue-tests-\(UUID())"; defaultsSuite = name
        return UserDefaults(suiteName: name)!
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Queue did not reach the expected state")
        throw NSError(domain: "ReviewQueueTests", code: 1)
    }
}
