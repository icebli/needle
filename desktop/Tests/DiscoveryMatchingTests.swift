import XCTest
@testable import NeedleDesktop

final class DiscoveryMatchingTests: XCTestCase {
    private let cudi = SpotifyArtist(id: "cudi", name: "Kid Cudi", uri: "spotify:artist:cudi")

    func testNoMatchRequiresWholeSourceArtistEvidence() {
        let artist = SpotifyArtist(id: "idk", name: "IDK", uri: "spotify:artist:idk")
        func source(_ raw: String, uploader: String?, title: String = "Unreleased Song") -> DiscoveryRecording {
            let candidate = Candidate(provider: "youtube", id: "source", url: "https://example.com/source", title: raw,
                uploader: uploader, durationMs: nil, thumbnailURL: nil, channelIsVerified: true)
            return DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .unknown)
        }
        for recording in [source("IDK HOW KARAN AUJLA | FOUR ME EP", uploader: "Rehaan Records"),
                          source("IDK HOW - Unreleased Song", uploader: "IDK HOW"),
                          source("Unreleased Song", uploader: nil), source("Unreleased Song", uploader: "IDK Fan Channel")] {
            let assessment = DiscoveryMatching.assessingCatalog(recording, tracks: [])
            XCTAssertEqual(assessment.availability, .unknown)
            XCTAssertTrue(assessment.detail?.contains("credit") == true)
        }
        for recording in [source("IDK - Unreleased Song", uploader: "Fan Channel"),
                          source("IDK \"Unreleased Song\"", uploader: nil),
                          source("Other & IDK - Unreleased Song", uploader: nil),
                          source("Unreleased Song w/ IDK", uploader: nil),
                          source("Unreleased Song", uploader: "IDK"), source("Unreleased Song", uploader: "IDK - Topic"),
                          source("Unreleased Song", uploader: "IDKVEVO")] {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording, tracks: []).availability, .noMatch)
        }
        let track = SpotifyCatalogTrack(id: "known", name: "Unreleased Song", uri: "spotify:track:known",
            artists: [SpotifyArtistCredit(id: artist.id, name: artist.name)])
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(source("Unreleased Song", uploader: nil), tracks: [track]).availability, .found)
    }

    func testWithCreditsPreserveBracketedAndBareVersionQualifiers() {
        let artist = SpotifyArtist(id: "tracy", name: "Lil Tracy", uri: "spotify:artist:tracy")
        let studio = SpotifyCatalogTrack(id: "studio", name: "Song", uri: "spotify:track:studio",
            artists: [SpotifyArtistCredit(id: artist.id, name: artist.name)])
        var uploads = ["Song [w/ Lil Tracy Demo]", "Song w/ Lil Tracy Producer Name Demo"]
        for qualifier in ["Demo", "Part 2", "Part2", "Pt2", "Clean", "Karaoke"] {
            uploads += ["Song (w/ Lil Tracy \(qualifier))", "Song w/ Lil Tracy \(qualifier)"]
        }
        for upload in uploads {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: artist), tracks: [studio]).availability, .noMatch, upload)
            XCTAssertEqual(DiscoveryMatching.catalogTitle(upload, artist: artist.name), upload)
        }
    }

    func testWithCreditsReleaseLabelsAndBonusTrackMetadataMatchCatalog() {
        let tracy = SpotifyArtist(id: "tracy", name: "Lil Tracy", uri: "spotify:artist:tracy")
        for title in ["giving girls cocaine", "white wine", "cobain"] {
            let upload = title + " w/ lil tracy (prod. Producer)"
            let track = SpotifyCatalogTrack(id: title, name: title, uri: "spotify:track:track",
                artists: [SpotifyArtistCredit(id: tracy.id, name: tracy.name)])
            XCTAssertEqual(DiscoveryMatching.catalogTitle(upload, artist: tracy.name), title)
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: tracy), tracks: [track]).availability, .found)
            for version in ["Live", "Remix", "Part 2"] {
                XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload + " - " + version, artist: tracy), tracks: [track]).availability, .noMatch)
            }
        }
        let sleepy = SpotifyArtist(id: "sleepy", name: "Sleepy Hallow", uri: "spotify:artist:sleepy")
        let deepEnd = SpotifyCatalogTrack(id: "deep", name: "Deep End Freestyle", uri: "spotify:track:deep",
            artists: [SpotifyArtistCredit(id: sleepy.id, name: sleepy.name)])
        let upload = "Sleepy Hallow ft. Fousheé - Deep End Freestyle (Official Video Release)"
        XCTAssertEqual(DiscoveryMatching.catalogTitle(upload, artist: sleepy.name), "Deep End Freestyle")
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: sleepy), tracks: [deepEnd]).availability, .found)
        let bonus = SpotifyCatalogTrack(id: "bonus", name: "Song - Bonus Track", uri: "spotify:track:bonus",
            artists: [SpotifyArtistCredit(id: cudi.id, name: cudi.name)])
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song", artist: cudi), tracks: [bonus]).availability, .found)
        for title in ["Song - Bonus Track (Live)", "Song (Bonus Track Remix)", "Song - Bonus Track - Part 2"] {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(title, artist: cudi), tracks: [bonus]).availability, .noMatch)
        }
    }

    func testLiveProducerCreditsAndPartialExtendedVersionRemainVisibleOnSpotify() {
        let tracy = SpotifyArtist(id: "tracy", name: "Lil Tracy", uri: "spotify:artist:tracy")
        let peepCredits = [SpotifyArtistCredit(id: "peep", name: "Lil Peep"), SpotifyArtistCredit(id: tracy.id, name: tracy.name)]
        for (upload, name) in [
            ("Your Favorite Dress (Prod Lederrick, BigHead & SouljahWitch)", "your favorite dress"),
            ("Awful Things ft. Lil Tracy (prod. by smokeasac x IIVI)", "Awful Things"),
            ("Awful Things (Produced By smokeasac x IIVI)", "Awful Things")
        ] {
            let track = SpotifyCatalogTrack(id: name, name: name, uri: "spotify:track:track", artists: peepCredits)
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: tracy), tracks: [track]).availability, .found)
            XCTAssertEqual(DiscoveryMatching.catalogTitle(upload, artist: tracy.name).lowercased(), name.lowercased())
        }
        let metro = SpotifyArtist(id: "metro", name: "Metro Boomin", uri: "spotify:artist:metro")
        let lowLife = SpotifyCatalogTrack(id: "low", name: "Low Life (feat. The Weeknd)", uri: "spotify:track:low",
            artists: [SpotifyArtistCredit(id: "future", name: "Future"), SpotifyArtistCredit(id: "weeknd", name: "The Weeknd")])
        let source = "Future + The Weeknd- Low Life [Prod. By Metro Boomin & Ben Billions]"
        let assessment = DiscoveryMatching.assessingCatalog(recording(source, artist: metro), tracks: [lowLife])
        XCTAssertEqual(assessment.availability, .unknown)
        XCTAssertTrue(assessment.detail?.contains("Metro Boomin") == true)
        XCTAssertNil(assessment.catalogURI)
        XCTAssertEqual(assessment.title, source)
        for upload in ["Low Life", "Other Artist + The Weeknd- Low Life", "Future + The Weeknd-Low Life", "Future + The Weeknd- Low Life (Live)"] {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: metro), tracks: [lowLife]).availability, .noMatch)
        }
        let extended = SpotifyCatalogTrack(id: "pursuit", name: "Pursuit Of Happiness - Extended Steve Aoki Remix",
            uri: "spotify:track:pursuit", artists: [SpotifyArtistCredit(id: cudi.id, name: cudi.name)])
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Pursuit Of Happiness(Steve Aoki Remix)", artist: cudi), tracks: [extended]).availability, .unknown)
        for upload in ["Pursuit Of Happiness (Other DJ Remix)", "Pursuit Of Happiness (Steve Aoki Live)", "Pursuit Of Happiness (Steve Aoki Remix 2)"] {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: cudi), tracks: [extended]).availability, .noMatch)
        }
    }

    func testProducerBracketCleanupPreservesVersionTailsAndNestedContent() {
        let track = SpotifyCatalogTrack(id: "song", name: "Song", uri: "spotify:track:song",
            artists: [SpotifyArtistCredit(id: cudi.id, name: cudi.name)])
        for upload in ["Song (Prod. By Producer - Demo)", "Song [Produced By Producer (Live)]",
                       "Song (Prod Producer Live)", "Song (Prod Producer Remix)", "Song (Prod Producer Demo)",
                       "Song (Prod Producer Part 2)", "Song [Prod Producer Part2]", "Song (Live (Prod Producer))"] {
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(upload, artist: cudi), tracks: [track]).availability, .noMatch)
            XCTAssertEqual(DiscoveryMatching.catalogTitle(upload, artist: cudi.name), upload)
        }
        let outsideVersion = "Song (Prod Producer) - Karaoke"
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording(outsideVersion, artist: cudi), tracks: [track]).availability, .noMatch)
        XCTAssertTrue(DiscoveryMatching.catalogTitle(outsideVersion, artist: cudi.name).contains("Karaoke"))
    }

    private func recording(_ title: String, artist: SpotifyArtist) -> DiscoveryRecording {
        let candidate = Candidate(provider: "soundcloud", id: "source", url: "https://example.com/source", title: title,
            uploader: artist.name, durationMs: nil, thumbnailURL: nil)
        return DiscoveryRecording(artist: artist, title: title, candidate: candidate, availability: .unknown)
    }

    func testCatalogAssessmentSeparatesUnqualifiedVersionsFromStrictMatches() {
        let credit = [SpotifyArtistCredit(id: cudi.id, name: cudi.name)]
        let studio = SpotifyCatalogTrack(id: "studio", name: "Song", uri: "spotify:track:studio", artists: credit)
        func recording(_ title: String) -> DiscoveryRecording {
            let candidate = Candidate(provider: "youtube", id: "source", url: "https://example.com/source", title: title,
                uploader: cudi.name, durationMs: nil, thumbnailURL: nil)
            return DiscoveryRecording(artist: cudi, title: title, candidate: candidate, availability: .unknown)
        }
        for version in ["Remix", "Live", "Demo"] {
            let track = SpotifyCatalogTrack(id: version, name: "Song (\(version))", uri: "spotify:track:version", artists: credit)
            let ambiguous = DiscoveryMatching.assessingCatalog(recording("Song"), tracks: [track])
            XCTAssertEqual(ambiguous.availability, .unknown)
            XCTAssertTrue(ambiguous.detail?.contains(track.name) == true)
            XCTAssertNil(ambiguous.catalogURI)
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song (\(version))"), tracks: [track]).availability, .found)
            XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song (\(version))"), tracks: [studio]).availability, .noMatch)
            let exact = DiscoveryMatching.assessingCatalog(recording("Song"), tracks: [track, studio])
            XCTAssertEqual(exact.availability, .found)
            XCTAssertEqual(exact.catalogURI, studio.uri)
        }
        for title in ["Song (Remix) [feat. Kid Cudi]", "Song - Remix (feat. Kid Cudi)"] {
            let track = SpotifyCatalogTrack(id: "remix", name: title, uri: "spotify:track:remix", artists: credit)
            let assessment = DiscoveryMatching.assessingCatalog(recording("Song"), tracks: [track])
            XCTAssertEqual(assessment.availability, .unknown, title)
            XCTAssertTrue(assessment.detail?.contains(title) == true)
            XCTAssertNil(assessment.catalogURI)
        }
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song - Part 2"), tracks: [studio]).availability, .noMatch)
        let otherPart = SpotifyCatalogTrack(id: "part", name: "Song 2 - Remix", uri: "spotify:track:part", artists: credit)
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song"), tracks: [otherPart]).availability, .noMatch)
        let wrongArtist = SpotifyCatalogTrack(id: "other", name: "Song - Remix", uri: "spotify:track:other",
            artists: [SpotifyArtistCredit(id: "other", name: "Other Artist")])
        XCTAssertEqual(DiscoveryMatching.assessingCatalog(recording("Song"), tracks: [wrongArtist]).availability, .noMatch)
    }

    func testQuotedArtistTitleAndIntrawordApostrophesMatchWithoutMergingWords() {
        let tory = SpotifyArtist(id: "tory", name: "Tory Lanez", uri: "spotify:artist:tory")
        let sayIt = SpotifyCatalogTrack(id: "say", name: "Say It", uri: "spotify:track:say",
            artists: [SpotifyArtistCredit(id: tory.id, name: tory.name)])
        for upload in ["Tory Lanez \"Say It\"", "Tory Lanez “Say It”", "Tory Lanez \"Say It\" (Official Video)"] {
            XCTAssertEqual(DiscoveryMatching.title(upload, artist: tory.name), "Say It")
            XCTAssertEqual(DiscoveryMatching.matchingTrack([sayIt], artist: tory, title: upload)?.id, sayIt.id)
        }
        let melly = SpotifyArtist(id: "melly", name: "YNW Melly", uri: "spotify:artist:melly")
        let song = SpotifyCatalogTrack(id: "223s", name: "223's (feat. 9lokknine)", uri: "spotify:track:223s",
            artists: [SpotifyArtistCredit(id: melly.id, name: melly.name)])
        XCTAssertEqual(DiscoveryMatching.matchingTrack([song], artist: melly, title: "223s ft. 9lokknine")?.id, song.id)
        XCTAssertEqual(DiscoveryMatching.normalized("223’s"), "223s")
        XCTAssertEqual(DiscoveryMatching.normalized("rock 'n' roll"), "rock n roll")
        XCTAssertNotEqual(DiscoveryMatching.normalized("Part 2"), DiscoveryMatching.normalized("Part 3"))
        XCTAssertNotEqual(DiscoveryMatching.normalized("Part II"), DiscoveryMatching.normalized("Part III"))
    }

    func testFeaturedArtistPrefixMatchesThroughVerifiedMainArtistCredit() {
        let credits = [SpotifyArtistCredit(id: "guetta", name: "David Guetta"),
                       SpotifyArtistCredit(id: cudi.id, name: cudi.name)]
        let track = SpotifyCatalogTrack(id: "memories", name: "Memories (feat. Kid Cudi)",
            uri: "spotify:track:memories", artists: credits)
        for marker in ["Feat.", "feat", "FT.", "ft", "Featuring"] {
            let upload = "David Guetta \(marker) Kid Cudi - Memories (Official Video)"
            XCTAssertEqual(DiscoveryMatching.title(upload, artist: cudi.name), "David Guetta \(marker) Kid Cudi - Memories")
            XCTAssertEqual(DiscoveryMatching.title(upload, artist: "David Guetta"), "Memories")
            XCTAssertEqual(DiscoveryMatching.matchingTrack([track], artist: cudi, title: upload)?.id, track.id)
        }
    }

    func testFeaturedArtistPrefixKeepsVersionsAndDashedTitleParts() {
        let track = SpotifyCatalogTrack(id: "memories", name: "Memories (feat. Kid Cudi)",
            uri: "spotify:track:memories", artists: [SpotifyArtistCredit(id: "guetta", name: "David Guetta"),
                      SpotifyArtistCredit(id: cudi.id, name: cudi.name)])
        for title in ["Memories (Remix)", "Memories (Live)", "Memories - Part 2", "Memories (Extended Version)"] {
            let upload = "David Guetta Feat. Kid Cudi - \(title) [Official Audio]"
            XCTAssertEqual(DiscoveryMatching.title(upload, artist: "David Guetta"), title)
            XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: cudi, title: upload))
        }
        XCTAssertEqual(DiscoveryMatching.title("Other Artist feat. Someone Else - Memories", artist: cudi.name),
                       "Other Artist feat. Someone Else - Memories")
        XCTAssertEqual(DiscoveryMatching.title("Memories - Kid Cudi's Version", artist: cudi.name), "Memories - Kid Cudi's Version")
    }

    func testFeaturedCreditBeforeDashDoesNotEraseSongBeforeRemixTail() {
        let track = SpotifyCatalogTrack(id: "remix", name: "Song (DJ Y Remix)", uri: "spotify:track:remix",
            artists: [SpotifyArtistCredit(id: cudi.id, name: cudi.name)])
        let title = "Song feat. Kid Cudi - DJ Y Remix"
        XCTAssertEqual(DiscoveryMatching.title(title, artist: cudi.name), title)
        XCTAssertEqual(DiscoveryMatching.matchingTrack([track], artist: cudi, title: title)?.id, track.id)
        let part = SpotifyCatalogTrack(id: "part", name: "Part 2", uri: "spotify:track:part", artists: track.artists)
        XCTAssertNil(DiscoveryMatching.matchingTrack([part], artist: cudi, title: "Song feat. Kid Cudi - Part 2"))
    }

    func testFeaturedCreditRetainsArbitraryDashedVersionTails() {
        let credits = [SpotifyArtistCredit(id: cudi.id, name: cudi.name)]
        let studio = SpotifyCatalogTrack(id: "song", name: "Song", uri: "spotify:track:song", artists: credits)
        for version in ["Demo", "Clean", "Karaoke", "Part 2"] {
            let unrelated = SpotifyCatalogTrack(id: version, name: version, uri: "spotify:track:other", artists: credits)
            for upload in ["Song feat. Kid Cudi - \(version)", "Song (feat. Kid Cudi - \(version))"] {
                XCTAssertEqual(DiscoveryMatching.title(upload, artist: cudi.name), upload)
                XCTAssertNil(DiscoveryMatching.matchingTrack([unrelated, studio], artist: cudi, title: upload))
                let versionTrack = SpotifyCatalogTrack(id: "version", name: "Song (\(version))", uri: "spotify:track:version", artists: credits)
                XCTAssertEqual(DiscoveryMatching.matchingTrack([versionTrack], artist: cudi, title: upload)?.id, versionTrack.id)
            }
        }
    }

    func testProducerCreditDoesNotHideCatalogTrackOrEraseRecordingVersions() {
        let melly = SpotifyArtist(id: "melly", name: "YNW Melly", uri: "spotify:artist:melly")
        let track = SpotifyCatalogTrack(id: "murder", name: "Murder on My Mind", uri: "spotify:track:murder",
            artists: [SpotifyArtistCredit(id: melly.id, name: melly.name)])
        XCTAssertEqual(DiscoveryMatching.matchingTrack([track], artist: melly,
            title: "MURDER ON MY MIND Prod By; SMKEXCLSV")?.id, track.id)
        for title in ["Murder on My Mind (Live)", "Murder on My Mind - Part 2", "Murder on My Mind (Remix)"] {
            XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: melly, title: title + " Prod By; SMKEXCLSV"))
        }
        for version in ["Remix", "Live", "Part 2", "Instrumental", "Extended Version", "Demo", "Clean", "Karaoke"] {
            XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: melly,
                title: "Murder on My Mind Prod By; SMKEXCLSV - " + version))
            XCTAssertNil(DiscoveryMatching.matchingTrack([track], artist: melly,
                title: "Murder on My Mind Prod By; SMKEXCLSV (" + version + ")"))
        }
    }
}
