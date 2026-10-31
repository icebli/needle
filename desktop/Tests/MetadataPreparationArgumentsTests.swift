import XCTest
@testable import NeedleDesktop

final class MetadataPreparationArgumentsTests: XCTestCase {
    func testPreparePassesOnlyPositiveSelectedSourceDuration() async throws {
        for duration in [251_000, nil, 0, -1] as [Int?] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("needle-prepare-arguments-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("needle-fixture")
            let arguments = directory.appendingPathComponent("arguments")
            let script = """
            #!/bin/sh
            printf '%s\\n' "$@" > '\(arguments.path)'
            echo '{"artist":"Artist","title":"Song (Weedmix)","album":"","album_artist":"Artist","artwork_url":"","source":"none","warnings":[],"source_url":"https://example.org/source"}'
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            var settings = NeedleSettings()
            settings.cliPath = executable.path
            let candidate = Candidate(provider: "test", id: "source", url: "https://example.org/source", title: "Artist - Song (Weedmix)", uploader: "Artist", durationMs: duration, thumbnailURL: nil)

            let draft = try await NeedleCLIService().prepareMetadata(artist: "Artist", title: "Song (Weedmix)", candidate: candidate, settings: settings).get()

            let passed = try String(contentsOf: arguments, encoding: .utf8).split(separator: "\n").map(String.init)
            if let duration, duration > 0 {
                let index = try XCTUnwrap(passed.firstIndex(of: "--source-duration-ms"))
                XCTAssertEqual(passed[index + 1], String(duration))
            } else {
                XCTAssertFalse(passed.contains("--source-duration-ms"))
            }
            XCTAssertEqual(draft.title, "Song (Weedmix)")
            XCTAssertEqual(draft.sourceURL, candidate.url)
        }
    }
}
