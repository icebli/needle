import XCTest
@testable import NeedleDesktop
import UniformTypeIdentifiers

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

    func testDropParserAcceptsHTTPLinksAndDeduplicatesAcrossProviders() {
        let values = SourceURLDropImporter.parse([
            "https://soundcloud.com/whethan/remix\nhttps://youtu.be/example",
            "https://soundcloud.com/whethan/remix"
        ])

        XCTAssertEqual(values, [
            "https://soundcloud.com/whethan/remix",
            "https://youtu.be/example"
        ])
    }

    func testDropParserRejectsFilesScriptsAndMalformedValues() {
        let credentialURL = ["https://user:password", "localhost/track"].joined(separator: "@")
        let values = SourceURLDropImporter.parse([
            "file:///tmp/track.mp3",
            "javascript:alert(1)",
            "ftp://example.com/track",
            credentialURL,
            "https:///missing-host",
            "not a URL",
            "https://soundcloud.com/whethan/remix"
        ])

        XCTAssertEqual(values, ["https://soundcloud.com/whethan/remix"])
    }

    func testDropParserPreservesInputOrderAndReportsLimits() {
        let values = (0..<105).map { "https://example.com/track\($0)" }
        let result = SourceURLDropImporter.parseResult(values + [values[0], "file:///tmp/track.mp3"])

        XCTAssertEqual(result.accepted.count, 100)
        XCTAssertEqual(result.accepted.first, values.first)
        XCTAssertEqual(result.accepted.last, values[99])
        XCTAssertEqual(result.duplicateCount, 1)
        XCTAssertEqual(result.invalidCount, 1)
        XCTAssertEqual(result.truncatedCount, 5)
    }

    func testDropImporterLoadsNSURLAndPlainTextFallbackInProviderOrder() async throws {
        let urlProvider = NSItemProvider(object: NSURL(string: "https://example.com/url")!)
        let fallbackProvider = NSItemProvider()
        fallbackProvider.registerDataRepresentation(forTypeIdentifier: UTType.url.identifier, visibility: .all) { completion in
            completion(nil, NSError(domain: "DropTest", code: 1))
            return Progress()
        }
        fallbackProvider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
            completion(Data("https://example.com/text".utf8), nil)
            return Progress()
        }

        let result = try await withCheckedThrowingContinuation { continuation in
            _ = SourceURLDropImporter.start(providers: [urlProvider, fallbackProvider]) { result in
                continuation.resume(returning: result)
            }
        }

        XCTAssertEqual(result.accepted, ["https://example.com/url", "https://example.com/text"])
        XCTAssertEqual(result.invalidCount, 0)
    }

    func testDroppedLinkAutomaticallySearchesAfterIdentityWithoutDownloading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-drop-search-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("needle-fixture")
        let script = #"""
        #!/bin/sh
        case "$1" in
        identify-url)
          printf '%s\n' '{"ok":true,"artist":"A","title":"T","uncertain":true}'
          ;;
        search)
          if [ "$8" != "https://example.com/source" ]; then exit 7; fi
          printf '%s\n' '{"ok":true,"candidates":[{"candidate":{"provider":"test","id":"exact","url":"https://example.com/exact","title":"A - T"},"score":{"status":"recommended","positives":[],"warnings":[],"rejects":[]}}]}'
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
        queue.add("https://example.com/manual", settings: settings)
        try await wait { queue.items.first?.state == .needsInput }
        XCTAssertNil(queue.items.first?.response, "Pasted links must still stop for identity review")

        queue.add("https://example.com/source", settings: settings, automaticallySearchLinks: true)

        try await wait { queue.items.last?.state == .ready }
        XCTAssertEqual(queue.items.last?.artist, "A")
        XCTAssertEqual(queue.items.last?.title, "T")
        XCTAssertEqual(queue.items.last?.sourceIdentityUncertain, true)
        XCTAssertEqual(queue.items.last?.response?.candidates.first?.candidate.url, "https://example.com/exact")
        XCTAssertTrue(queue.items.last?.detail?.contains("source hints") == true)
        XCTAssertTrue(history.tracks.isEmpty, "Automatic link search must never download or save audio")
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
        prepare)
          printf '%s\n' '{"artist":"A","title":"T","album":"","album_artist":"A","artwork_url":"","source":"request","warnings":[],"source_url":"https://example.com/exact"}'
          ;;
        get)
          case "$*" in *'"title":"Reviewed"'*) ;; *) exit 1 ;; esac
          sleep 1
          printf '%s\n' '{"ok":true,"saved_path":"/tmp/needle-queue-test.mp3","artist":"A","title":"Reviewed","album":"","source_url":"https://example.com/exact"}'
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
        let prepared = await queue.prepareMetadata(candidate, itemID: first.id)
        var draft = try XCTUnwrap(prepared)
        draft.title = "Reviewed"
        queue.approve(candidate, itemID: first.id, spotify: false, approved: draft)
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
