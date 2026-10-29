import XCTest
import Darwin
@testable import NeedleDesktop

@MainActor
final class AudioPreviewProcessTests: XCTestCase {
    func testPreviewDrainsLargeStderrAndBecomesPlayable() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let service = AudioPreviewService(ytDLPPath: fixture.script.path)
        let candidate = makeCandidate(url: "https://example.com/fast")
        service.start(candidate: candidate)
        do { try await waitUntil { if case .ready = service.state { return true }; return false } }
        catch { XCTFail("preview did not become ready: \(service.state)") ; return }

        XCTAssertEqual(service.candidateID, candidate.id)
        XCTAssertGreaterThan(service.duration, 0)
        service.togglePlayback()
        XCTAssertTrue(service.isPlaying)
        service.seek(to: 0.2)
        XCTAssertEqual(service.elapsed, 0.2, accuracy: 0.05)
        service.stop()
        XCTAssertEqual(service.state, .idle)
        service.start(candidate: candidate)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        XCTAssertEqual(service.elapsed, 0.2, accuracy: 0.1)
        service.seek(to: 0)
        service.stop()
        service.start(candidate: candidate)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        XCTAssertEqual(service.elapsed, 0, accuracy: 0.05)
        service.stop()
    }

    func testSameTimestampComparisonAndFailedPreviewDoesNotCreateCacheEntry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let service = AudioPreviewService(ytDLPPath: fixture.script.path)
        let first = makeCandidate(url: "https://example.com/compare-first")
        let second = makeCandidate(url: "https://example.com/compare-second")
        service.start(candidate: first)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        service.seek(to: 0.2)
        service.start(candidate: second)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        XCTAssertEqual(service.elapsed, 0.2, accuracy: 0.1)
        service.keepTimestampAcrossCandidates = false
        service.seek(to: 0)
        service.start(candidate: first)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        XCTAssertEqual(service.elapsed, 0.2, accuracy: 0.1)
        service.stop()

        let broken = makeCandidate(url: "https://example.com/broken")
        service.start(candidate: broken)
        try await waitUntil { if case .failed = service.state { return true }; return false }
        let cache = AudioPreviewService.previewCacheDirectory(for: broken.id, sourceURL: broken.candidate.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("excerpt.mp3").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("complete").path))
        service.stop()
    }

    func testStartingAnotherCandidateCancelsThePreviousProcess() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let service = AudioPreviewService(ytDLPPath: fixture.script.path)
        service.start(candidate: makeCandidate(url: "https://example.com/slow"))
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.marker.path) }
        let oldPID = try XCTUnwrap(Int32(String(contentsOf: fixture.marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let replacement = makeCandidate(url: "https://example.com/fast")
        service.start(candidate: replacement)
        do { try await waitUntil { if case .ready = service.state { return true }; return false } }
        catch { XCTFail("replacement preview did not become ready: \(service.state)") ; return }

        XCTAssertEqual(service.candidateID, replacement.id)
        try await waitUntil { kill(oldPID, 0) != 0 }
        service.stop()
        XCTAssertEqual(service.state, .idle)
    }

    func testCancellationEscalatesWhenPreviewChildIgnoresSIGTERM() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let service = AudioPreviewService(ytDLPPath: fixture.script.path)
        service.start(candidate: makeCandidate(url: "https://example.com/ignore-term"))
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.marker.path) }
        let childPID = try XCTUnwrap(Int32(String(contentsOf: fixture.marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        service.stop()
        try await waitUntil { kill(childPID, 0) != 0 }
        XCTAssertEqual(service.state, .idle)
    }

    func testCompletedPreviewIsReusedAndCacheStaysBounded() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let service = AudioPreviewService(ytDLPPath: fixture.script.path)
        let first = makeCandidate(url: "https://example.com/cache-first")
        service.start(candidate: first)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        service.stop()
        let firstCount = try String(contentsOf: fixture.script.appendingPathExtension("count"), encoding: .utf8)
            .split(separator: "\n").count

        service.start(candidate: first)
        try await waitUntil { if case .ready = service.state { return true }; return false }
        service.stop()
        let reusedCount = try String(contentsOf: fixture.script.appendingPathExtension("count"), encoding: .utf8)
            .split(separator: "\n").count
        XCTAssertEqual(reusedCount, firstCount, "a completed candidate preview should come from cache")

        for index in 0..<3 {
            service.start(candidate: makeCandidate(url: "https://example.com/cache-\(index)"))
            try await waitUntil { if case .ready = service.state { return true }; return false }
            service.stop()
        }
        let root = AudioPreviewService.previewCacheDirectory(for: first.id).deletingLastPathComponent()
        let cachedDirectories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("excerpt.mp3").path) &&
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("complete").path)
            }
        XCTAssertLessThanOrEqual(cachedDirectories.count, 3)
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !condition() {
            if Date() >= deadline { throw PreviewTestError.timeout }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private enum PreviewTestError: Error { case timeout }

    private func makeCandidate(url: String) -> CandidateResult {
        CandidateResult(candidate: Candidate(provider: "test", id: UUID().uuidString, url: url,
                                             title: "Test preview", uploader: "Fixture", durationMs: 1_000,
                                             thumbnailURL: nil),
                        score: Score(confidence: 1, status: "recommended", positives: [], warnings: [], rejects: []))
    }

    private func makeFixture() throws -> (directory: URL, script: URL, marker: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-preview-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("yt-dlp")
        let body = #"""
#!/bin/sh
output=""
previous=""
for arg in "$@"; do
  if [ "$previous" = "-o" ]; then output="$arg"; fi
  previous="$arg"
done
printf '%300000s' 'x' >&2
printf 'run\n' >> "$0.count"
output=$(printf '%s' "$output" | sed 's/%(ext)s/mp3/')
case "$*" in
  *--download-sections*) exit 1 ;;
esac
case "$*" in
  *broken*) : > "$output"; exit 1 ;;
esac
case "$*" in
  *slow*) echo "$$" > "$0.marker"; sleep 5 ;;
esac
case "$*" in
  *ignore-term*) trap '' TERM; sleep 30 & child=$!; echo "$child" > "$0.marker"; wait "$child" ;;
esac
ffmpeg -loglevel error -y -f lavfi -i sine=frequency=440:sample_rate=44100 -t 1 "$output"
"""#
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (directory, script, script.appendingPathExtension("marker"))
    }
}
