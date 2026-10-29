import AppKit
import XCTest
@testable import NeedleDesktop

final class ArtworkTests: XCTestCase {
    func testCLIMetadataPreservesArtworkAndItsReleaseIdentity() throws {
        let json = Data(#"{"artist":"Artist","title":"Song","album":"Album","duration_ms":180000,"artwork_url":"https://example.com/cover.jpg","artwork":{"url":"https://example.com/cover.jpg","provider":"cover_art_archive","release_id":"edition","release_group_id":"group"}}"#.utf8)
        let metadata = try NeedleCLIService.parseLastJSON(Metadata.self, data: json)
        XCTAssertEqual(metadata.durationMs, 180000)
        XCTAssertEqual(metadata.resolvedArtwork?.url, "https://example.com/cover.jpg")
        XCTAssertEqual(metadata.resolvedArtwork?.releaseId, "edition")
        XCTAssertEqual(metadata.resolvedArtwork?.releaseGroupId, "group")
    }

    func testLegacyArtworkURLIsRetainedWithoutInventingReleaseProvenance() throws {
        let metadata = try NeedleCLIService.parseLastJSON(Metadata.self, data: Data(#"{"artist":"Artist","artwork_url":"https://example.com/cover.jpg"}"#.utf8))
        XCTAssertEqual(metadata.resolvedArtwork?.url, "https://example.com/cover.jpg")
        XCTAssertNil(metadata.resolvedArtwork?.releaseId)
    }

    @MainActor
    func testBookmarkRestoresAlbumArtworkAndExactSource() throws {
        let suite = "NeedleArtwork.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let candidate = Candidate(provider: "youtube", id: "source", url: "https://youtube.com/watch?v=source", title: "Upload", uploader: "Uploader", durationMs: nil, thumbnailURL: "https://example.com/upload.jpg")
        let artwork = ArtworkReference(url: "https://example.com/cover.jpg", provider: "cover_art_archive", releaseId: "edition", releaseGroupId: "group")
        let store = BookmarkStore(defaults: defaults)
        store.toggle(artist: "Artist", title: "Song", candidate: candidate, artwork: artwork)
        let restored = BookmarkStore(defaults: defaults)
        XCTAssertEqual(restored.items.first?.artwork, artwork)
        XCTAssertEqual(restored.items.first?.candidate.thumbnailURL, candidate.thumbnailURL)
        let queue = ReviewQueue(defaults: defaults, history: HistoryStore(defaults: defaults))
        queue.addBookmark(try XCTUnwrap(restored.items.first), settings: NeedleSettings())
        XCTAssertEqual(queue.selected?.response?.metadata?.resolvedArtwork, artwork)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.url, candidate.url)
    }

    @MainActor
    func testOldBookmarkWithoutArtworkStillDecodes() throws {
        let candidate = Candidate(provider: "youtube", id: "source", url: "https://youtube.com/watch?v=source", title: "Song", uploader: nil, durationMs: nil, thumbnailURL: nil)
        let old = ReleaseBookmark(artist: "Artist", title: "Song", candidate: candidate)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object.removeValue(forKey: "artwork")
        let decoded = try JSONDecoder().decode(ReleaseBookmark.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.artwork)
        XCTAssertEqual(decoded.candidate.url, candidate.url)
    }

    func testCachedCoverSurvivesNewCacheInstanceWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let png = try Self.imageData()
        let url = try XCTUnwrap(URL(string: "https://example.com/cover.png"))
        let cache = AlbumArtworkCache(directory: directory, loader: { _ in png })
        let first = await cache.data(for: url)
        XCTAssertEqual(first, png)
        let offline = AlbumArtworkCache(directory: directory, loader: { _ in throw URLError(.notConnectedToInternet) })
        let restored = await offline.data(for: url)
        XCTAssertEqual(restored, png)
    }

    func testInvalidImageIsNotPersisted() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = AlbumArtworkCache(directory: directory, loader: { _ in Data("not an image".utf8) })
        let result = await cache.data(for: try XCTUnwrap(URL(string: "https://example.com/invalid")))
        XCTAssertNil(result)
        XCTAssertTrue((try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) ?? true)
    }

    private static func imageData() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
}
