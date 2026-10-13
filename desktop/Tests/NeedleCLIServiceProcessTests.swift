import Foundation
import Darwin
import XCTest
@testable import NeedleDesktop

final class NeedleCLIServiceProcessTests: XCTestCase {
    func testSearchPassesLiteralArgumentsAndAdvancedSettings() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
set -eu
printf '%s\n' "$@" > "$NEEDLE_TEST_ARGS"
printf 'human stdout\n'
printf '%0100d\n' 0 >&2
printf '%s\n' '{"ok":true,"request":{"artist":"The & Artist","title":"A title"},"metadata":null,"candidates":[],"error":null}'
"""#
        )
        var settings = NeedleSettings()
        settings.cliPath = fixture.path
        settings.provider = "yt-dlp"
        settings.albumHint = "Album & Side"
        settings.noMetadata = true
        settings.durationOverride = "123.45"

        let result = await NeedleCLIService().search(
            artist: "The & Artist", title: "A title", sourceURL: "https://example.com/a?x=1&y=2", settings: settings
        )
        guard case .success(let response) = result else { return XCTFail("search failed: \(result)") }
        XCTAssertEqual(response.request?.artist, "The & Artist")
        XCTAssertEqual(Set(try fixture.arguments()), Set([
            "search", "The & Artist", "A title", "--json", "--url", "https://example.com/a?x=1&y=2",
            "--source", "yt-dlp", "--album", "Album & Side", "--no-metadata", "--duration-override", "123.45"
        ]))
    }

    func testSearchDrainsLargeStderrAndParsesFinalJSON() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
set -eu
dd if=/dev/zero bs=1024 count=128 2>/dev/null | tr '\0' 'e' >&2
printf '\n' >&2
printf 'noise\n'
printf '%s\n' '{"ok":true,"request":{"artist":"A","title":"T"},"metadata":null,"candidates":[],"error":null}'
"""#
        )
        var settings = NeedleSettings(); settings.cliPath = fixture.path
        let result = await NeedleCLIService().search(artist: "A", title: "T", settings: settings)
        guard case .success(let response) = result else { return XCTFail("search failed or deadlocked: \(result)") }
        XCTAssertTrue(response.ok)
    }

    func testGetReportsSplitProgressAndUsesAuthoritativeSavedFields() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
set -eu
printf '%s\n' "$@" > "$NEEDLE_TEST_ARGS"
printf 'download started\n'
printf '{"event":"progress","stage":"down' >&2
sleep 0.02
printf 'load"}\n' >&2
printf '{"event":"progress","stage":"tag"}\n' >&2
printf '%s\n' '{"ok":true,"saved_path":"/tmp/needle-saved.mp3","source_url":"https://example.com/original?raw=1","artist":"Canonical Artist","title":"Canonical Title","album":"Canonical Album"}'
"""#
        )
        var settings = NeedleSettings(); settings.cliPath = fixture.path
        settings.format = "flac"
        let original = TrackRequest(artist: "Requested Artist", title: "Requested Title", album: "Requested Album", sourceURL: "https://example.com/original?raw=1")
        let progress = LockedArray<String>()
        let result = await NeedleCLIService().get(track: original, settings: settings) { progress.append($0) }
        guard case .success(let saved) = result else { return XCTFail("get failed: \(result)") }
        XCTAssertEqual(saved.savedPath, "/tmp/needle-saved.mp3")
        XCTAssertEqual(saved.artist, "Canonical Artist")
        XCTAssertEqual(saved.title, "Canonical Title")
        XCTAssertEqual(saved.album, "Canonical Album")
        XCTAssertEqual(progress.values, ["download", "tag"])
        XCTAssertEqual(try fixture.arguments(), [
            "get", "Requested Artist", "Requested Title", "--url", "https://example.com/original?raw=1", "--yes", "--strict", "--json", "--events", "--format", "flac", "--album", "Requested Album"
        ])
    }

    func testDoctorSurfacesFailureStderrAndNonZeroStatus() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
printf 'doctor could not find ffmpeg\n' >&2
exit 7
"""#
        )
        var settings = NeedleSettings(); settings.cliPath = fixture.path
        let result = await NeedleCLIService().doctor(settings: settings)
        guard case .failure(let error) = result else { return XCTFail("doctor unexpectedly succeeded") }
        XCTAssertTrue(error.localizedDescription.contains("doctor could not find ffmpeg"))
    }

    func testDoctorReturnsStructuredNotReadyStatus() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
printf '%s\n' '{"ok":false,"tools":[{"name":"ffmpeg","ok":false,"optional":false,"message":"missing"}]}'
"""#
        )
        var settings = NeedleSettings(); settings.cliPath = fixture.path
        let result = await NeedleCLIService().doctor(settings: settings)
        guard case .success(let response) = result else { return XCTFail("doctor failed to decode structured readiness response: \(result)") }
        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.tools.first?.name, "ffmpeg")
        XCTAssertEqual(response.tools.first?.ok, false)
    }

    func testCancelTerminatesLongRunningChildProcess() async throws {
        let fixture = try CLIFixture(script: #"""
#!/bin/bash
set -eu
sleep 30 &
child=$!
echo "$child" > "$NEEDLE_TEST_CHILD"
wait "$child"
"""#
        )
        var settings = NeedleSettings(); settings.cliPath = fixture.path
        let service = NeedleCLIService()
        let task = Task { await service.search(artist: "A", title: "T", settings: settings) }
        try await waitUntil { FileManager.default.fileExists(atPath: fixture.childPath) }
        await service.cancel()
        _ = await task.value
        let childPID = Int32(try String(contentsOfFile: fixture.childPath).trimmingCharacters(in: .whitespacesAndNewlines))!
        try await waitUntil(timeout: 5) { kill(childPID, 0) != 0 }
    }
}

private final class CLIFixture {
    let directory: URL
    let path: String
    let argsPath: String
    let childPath: String

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-cli-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("needle").path
        argsPath = directory.appendingPathComponent("args").path
        childPath = directory.appendingPathComponent("child").path
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        setenv("NEEDLE_TEST_ARGS", argsPath, 1)
        setenv("NEEDLE_TEST_CHILD", childPath, 1)
    }

    func arguments() throws -> [String] {
        try String(contentsOfFile: argsPath).split(whereSeparator: \.isNewline).map(String.init)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class LockedArray<Element>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    func append(_ value: Element) { lock.lock(); defer { lock.unlock() }; storage.append(value) }
    var values: [Element] { lock.lock(); defer { lock.unlock() }; return storage }
}

private func waitUntil(timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { throw NSError(domain: "NeedleCLIServiceProcessTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for fixture state"]) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
