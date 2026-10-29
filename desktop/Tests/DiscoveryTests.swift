import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryTests: XCTestCase {
    private let artist = SpotifyArtist(id: "a", name: "Doechii", uri: "spotify:artist:a")

    func testSavedDiscoverResultsAgainstSpotifyCatalogFixtures() throws {
        struct Fixture: Decodable {
            let artist: SpotifyArtist
            let title: String
            let upload: String
            let tracks: [SpotifyCatalogTrack]
            let expectedID: String?
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: root.appendingPathComponent("tests/fixtures/metadata/discover-spotify.json")))
        XCTAssertEqual(fixtures.count, 8)
        for fixture in fixtures {
            for title in [fixture.title, fixture.upload] {
                XCTAssertEqual(DiscoveryMatching.matchingTrack(fixture.tracks, artist: fixture.artist, title: title)?.id,
                               fixture.expectedID, title)
            }
        }
    }

    func testUploadLabelsDoNotEraseVersionsOrSeriesNumbers() {
        let track = SpotifyCatalogTrack(id: "t", name: "No Suburban, Pt. 2", uri: "spotify:track:t", artists: [SpotifyArtistCredit(id: artist.id, name: artist.name)])
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([track], artist: artist, title: "No Suburban, Pt. 2 (Official Audio Visualizer)"))
        for title in ["No Suburban, Pt. 1 (Visualizer)", "No Suburban (Visualizer)", "No Suburban, Pt. 2 (Live Visualizer)"] {
            XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: artist, title: title))
        }
        let remix = SpotifyCatalogTrack(id: "r", name: "Song (DJ Y Remix)", uri: "spotify:track:r", artists: track.artists)
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([remix], artist: artist, title: "Song feat. X - DJ Y Remix"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([remix], artist: artist, title: "Song feat. X - DJ Z Remix"))
        let studio = SpotifyCatalogTrack(id: "s", name: "Song", uri: "spotify:track:s", artists: track.artists)
        for title in ["Song (with X - Live)", "Song (feat. X - Remix)", "Song (with X (Live))"] {
            XCTAssertNil(DiscoveryMatching.matchingTrack([studio], artist: artist, title: title))
        }
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([remix], artist: artist, title: "Song (with X - DJ Y Remix)"))
    }

    func testLikeAVersionSessionRemainsDistinctFromStudioAndOtherCovers() {
        let denzel = SpotifyArtist(id: "d", name: "Denzel Curry", uri: "spotify:artist:d")
        let credits = [SpotifyArtistCredit(id: denzel.id, name: denzel.name)]
        let session = SpotifyCatalogTrack(id: "s", name: "Bulls on Parade - triple j Like A Version", uri: "spotify:track:s", artists: credits)
        let studio = SpotifyCatalogTrack(id: "o", name: "Bulls on Parade", uri: "spotify:track:o", artists: credits)
        let upload = "Denzel Curry covers Rage Against The Machine 'Bulls On Parade' for Like A Version"
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([session], artist: denzel, title: upload))
        XCTAssertNil(DiscoveryMatching.matchingTrack([studio], artist: denzel, title: upload))
        XCTAssertNil(DiscoveryMatching.matchingTrack([session], artist: denzel, title: "Other Artist covers Rage Against The Machine 'Bulls On Parade' for Like A Version"))
    }

    func testLutherMatchesSpotifyWithArtistCreditWithoutErasingVersions() {
        let kendrick = SpotifyArtist(id: "2YZyLoL8N0Wb9xBt1NhZWg", name: "Kendrick Lamar", uri: "spotify:artist:2YZyLoL8N0Wb9xBt1NhZWg")
        let credits = [SpotifyArtistCredit(id: kendrick.id, name: kendrick.name), SpotifyArtistCredit(id: "7tYKF4w9nC0nq9CsPZTHyP", name: "SZA")]
        let original = SpotifyCatalogTrack(id: "45J4avUb9Ni0bnETYaYFVJ", name: "luther (with sza)", uri: "spotify:track:45J4avUb9Ni0bnETYaYFVJ", artists: credits)
        let upload = "Kendrick Lamar - luther (Official Audio)"
        XCTAssertEqual(DiscoveryMatching.matchingTrack([original], artist: kendrick, title: upload)?.uri, original.uri)
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([original], artist: kendrick, title: "luther [with SZA]"))
        for version in ["Live", "Remix", "Acoustic", "Instrumental"] {
            XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: kendrick, title: "luther (with SZA) (\(version))"))
            let alternate = SpotifyCatalogTrack(id: "version", name: "luther (with sza) (\(version))", uri: "spotify:track:version", artists: credits)
            XCTAssertNil(DiscoveryMatching.matchingTrack([alternate], artist: kendrick, title: upload))
            XCTAssertNotNil(DiscoveryMatching.matchingTrack([alternate], artist: kendrick, title: "luther (\(version))"))
        }
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: kendrick, title: "luther with love"))
    }

    func testCatalogMatchingPreservesRecordingVersionsAndArtistIdentity() {
        let original = SpotifyCatalogTrack(id: "t", name: "NISSAN ALTIMA", uri: "spotify:track:t",
            artists: [SpotifyArtistCredit(id: "a", name: "Doechii")])
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([original], artist: artist, title: "Nissan Altima"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: artist, title: "Nissan Altima (Whethan Remix)"))
        let wrongArtist = SpotifyCatalogTrack(id: "other", name: "NISSAN ALTIMA", uri: "spotify:track:other",
            artists: [SpotifyArtistCredit(id: "b", name: "Someone Else")])
        XCTAssertNil(DiscoveryMatching.matchingTrack([wrongArtist], artist: artist, title: "Nissan Altima"))
    }

    func testCatalogMatchingRecognizesNeutralUploadDecorationsAndArtistPrefixes() {
        let drake = SpotifyArtist(id: "drake", name: "Drake", uri: "spotify:artist:drake")
        let originals = [
            SpotifyCatalogTrack(id: "time-flies", name: "Time Flies", uri: "spotify:track:time-flies", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")]),
            SpotifyCatalogTrack(id: "not-you-too", name: "Not You Too", uri: "spotify:track:not-you-too", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")]),
            SpotifyCatalogTrack(id: "hours", name: "Hours In Silence", uri: "spotify:track:hours", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")]),
            SpotifyCatalogTrack(id: "one-dance", name: "One Dance", uri: "spotify:track:one-dance", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")]),
        ]

        XCTAssertNotNil(DiscoveryMatching.matchingTrack(originals, artist: drake, title: "Drake - Time Flies (Audio)"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack(originals, artist: drake, title: "Not You Too (Audio) ft. Chris Brown"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack(originals, artist: drake, title: "Drake, 21 Savage - Hours In Silence (Audio)"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack(originals, artist: drake, title: "One Dance (feat. WizKid & Kyla) - Drake"))
    }

    func testCatalogMatchingKeepsMeaningfulRecordingVersionsDistinct() {
        let drake = SpotifyArtist(id: "drake", name: "Drake", uri: "spotify:artist:drake")
        let original = SpotifyCatalogTrack(id: "original", name: "Time Flies", uri: "spotify:track:original", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")])
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Drake - Time Flies (Live)"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Drake - Time Flies (Remix)"))
    }

    func testFeaturedArtistDecorationsDoNotEraseFollowingVersionTails() {
        let drake = SpotifyArtist(id: "drake", name: "Drake", uri: "spotify:artist:drake")
        let original = SpotifyCatalogTrack(id: "original", name: "Song", uri: "spotify:track:original", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")])
        let remix = SpotifyCatalogTrack(id: "remix", name: "Song (Remix)", uri: "spotify:track:remix", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")])
        let live = SpotifyCatalogTrack(id: "live", name: "Song (Live)", uri: "spotify:track:live", artists: [SpotifyArtistCredit(id: "drake", name: "Drake")])

        XCTAssertNotNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Song feat. Drake"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Song feat. Drake (Remix)"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Song feat. Drake (Live)"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([original], artist: drake, title: "Song feat. Drake - Remix"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([remix], artist: drake, title: "Song feat. Drake (Remix)"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([remix], artist: drake, title: "Song feat. Drake - Remix"))
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([live], artist: drake, title: "Song feat. Drake (Live)"))
    }

    func testFeaturedFavoriteArtistMatchesMainArtistUploadPrefix() {
        let drake = SpotifyArtist(id: "drake", name: "Drake", uri: "spotify:artist:drake")
        let track = SpotifyCatalogTrack(id: "odio", name: "Odio (feat. Drake)", uri: "spotify:track:odio",
            artists: [SpotifyArtistCredit(id: "romeo", name: "Romeo Santos"), SpotifyArtistCredit(id: "drake", name: "Drake")])
        XCTAssertNotNil(DiscoveryMatching.matchingTrack([track], artist: drake, title: "Romeo Santos - Odio Feat. Drake (Lyric Video)"))
        XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: drake, title: "Romeo Santos - Odio Feat. Drake (Remix)"))
    }

    func testTitleCleanupRetainsRemixAndLiveMarkers() {
        XCTAssertEqual(DiscoveryMatching.title("Doechii - Nissan Altima (Whethan Remix) [Official Audio]", artist: "Doechii"), "Nissan Altima (Whethan Remix)")
        XCTAssertEqual(DiscoveryMatching.title("Other Artist - Song (Live)", artist: "Doechii"), "Other Artist - Song (Live)")
    }

    func testDiscoveryQueueKeepsExactSourceWithoutDownloadingAndDeduplicates() {
        let suite = "NeedleDiscoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = HistoryStore(defaults: defaults)
        let queue = ReviewQueue(defaults: defaults, history: history)
        let candidate = Candidate(provider: "soundcloud", id: "remix", url: "https://soundcloud.com/whethan/remix",
            title: "Nissan Altima (Whethan Remix)", uploader: "Whethan", durationMs: 180000, thumbnailURL: nil,
            viewCount: 12345, audioBitrateKbps: 160)
        let recording = DiscoveryRecording(artist: artist, title: candidate.title, candidate: candidate, availability: .noMatch)
        queue.addDiscovery(recording, settings: NeedleSettings())
        queue.addDiscovery(recording, settings: NeedleSettings())
        XCTAssertEqual(queue.items.count, 1)
        XCTAssertEqual(queue.selected?.sourceURL, candidate.url)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.url, candidate.url)
        XCTAssertEqual(queue.selected?.response?.candidates.first?.candidate.audioBitrateKbps, 160)
        XCTAssertEqual(queue.selected?.state, .ready)
        XCTAssertTrue(queue.selected?.sourceIdentityUncertain == true)
        XCTAssertTrue(history.tracks.isEmpty)
        XCTAssertEqual(queue.activeDownloads, 0)
    }

    func testLibraryDeduplicationRequiresAnExistingFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp3")
        try Data([0]).write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }
        let candidate = Candidate(provider: "youtube", id: "x", url: "https://www.youtube.com/watch?v=x", title: "Song", uploader: nil, durationMs: nil, thumbnailURL: nil)
        var track = TrackRequest(artist: "Doechii", title: "Song", sourceURL: candidate.url, savedPath: path.path)
        XCTAssertTrue(DiscoveryMatching.isInLibrary(candidate: candidate, artist: "Doechii", title: "Song", tracks: [track]))
        track.savedPath = path.path + ".missing"
        XCTAssertFalse(DiscoveryMatching.isInLibrary(candidate: candidate, artist: "Doechii", title: "Song", tracks: [track]))
    }
}
