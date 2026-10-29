import Foundation
import XCTest
@testable import NeedleDesktop

final class BrowserSessionTests: XCTestCase {
    @MainActor
    func testCLIChildReceivesSelectedBrowser() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("needle")
        try #"""
#!/bin/sh
printf '%s' "$NEEDLE_COOKIES_FROM_BROWSER"
"""#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var settings = NeedleSettings()
        settings.cliPath = script.path
        settings.browserSession = .chrome
        settings.browserProfile = "Profile 2"
        let service = NeedleCLIService()
        let enabled = try await service.runJSONCommand(["fixture"], settings: settings)
        XCTAssertEqual(String(decoding: enabled, as: UTF8.self), "chrome:Profile 2")
        settings.browserSession = nil
        let disabled = try await service.runJSONCommand(["fixture"], settings: settings)
        XCTAssertTrue(disabled.isEmpty)
    }

    func testOldSettingsAndHistorySnapshotsRemainDecodable() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(NeedleSettings())) as? [String: Any])
        object.removeValue(forKey: "browserSession")
        object.removeValue(forKey: "browserProfile")
        object["playlistName"] = "Keep my playlist"
        let oldSettings = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(NeedleSettings.self, from: oldSettings)
        XCTAssertNil(decoded.browserSession)
        XCTAssertEqual(decoded.playlistName, "Keep my playlist")
        let track = TrackRequest(artist: "Keep artist", title: "Keep song", settingsSnapshot: decoded)
        var history = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode([track])) as? [[String: Any]])
        history[0]["settingsSnapshot"] = object
        let restored = try JSONDecoder().decode([TrackRequest].self, from: JSONSerialization.data(withJSONObject: history))
        XCTAssertEqual(restored.first?.artist, track.artist)
        XCTAssertEqual(restored.first?.settingsSnapshot?.playlistName, "Keep my playlist")
    }

    func testOldSnapshotsInheritCurrentBrowserWithoutChangingTrackOptions() {
        var old = NeedleSettings()
        old.format = "flac"
        old.playlistName = "Original playlist"
        var current = NeedleSettings()
        current.browserSession = .zen
        current.browserProfile = "/tmp/Zen Profile"
        let effective = BrowserSession.sessionSettings(old, current: current)
        XCTAssertEqual(effective.browserSession, .zen)
        XCTAssertEqual(effective.browserProfile, "/tmp/Zen Profile")
        XCTAssertEqual(effective.format, "flac")
        XCTAssertEqual(effective.playlistName, "Original playlist")
        current.browserSession = nil
        old.browserSession = .firefox
        XCTAssertNil(BrowserSession.sessionSettings(old, current: current).browserSession)
    }

    func testDisabledClearsInheritedSelectorAndEnabledMatchesPreview() throws {
        var settings = NeedleSettings()
        XCTAssertNil(try BrowserSession.environment(settings: settings, inherited: [BrowserSession.environmentKey: "chrome"])[BrowserSession.environmentKey])
        XCTAssertEqual(try BrowserSession.arguments(settings: settings), [])
        settings.browserSession = .firefox
        settings.browserProfile = "/tmp/Profile with spaces"
        let selector = "firefox:/tmp/Profile with spaces"
        XCTAssertEqual(try BrowserSession.environment(settings: settings, inherited: [:])[BrowserSession.environmentKey], selector)
        XCTAssertEqual(try BrowserSession.arguments(settings: settings), ["--cookies-from-browser", selector])
    }

    func testZenUsesInstalledRelativeDefaultWithSpaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = root.appendingPathComponent("Profiles/Default Profile")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try "[Profile0]\nPath=Profiles/Other\nIsRelative=1\nDefault=1\n[InstallABC]\nDefault=Profiles/Default Profile\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try BrowserSession.zenDefaultProfile(root: root).path, profile.path)
        try "[Profile0]\nPath=Profiles/Default Profile\nIsRelative=1\nDefault=1\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try BrowserSession.zenDefaultProfile(root: root).path, profile.path)
        try FileManager.default.removeItem(at: profile)
        XCTAssertThrowsError(try BrowserSession.zenDefaultProfile(root: root)) { error in
            XCTAssertTrue(error.localizedDescription.contains("profile folder is missing"))
        }
    }

    func testZenDoesNotGuessProfileWithoutDefault() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[Profile0]\nPath=Profiles/only-profile\nIsRelative=1\n".write(to: root.appendingPathComponent("profiles.ini"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try BrowserSession.zenDefaultProfile(root: root))
    }
}
