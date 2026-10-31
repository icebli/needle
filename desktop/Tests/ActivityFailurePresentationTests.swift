import XCTest
@testable import NeedleDesktop

final class ActivityFailurePresentationTests: XCTestCase {
    func testArtworkFailureShowsTheCauseWithoutProgressOutputAndPreservesTechnicalDetails() throws {
        for title in ["Molly", "Prayer"] {
            var track = TrackRequest(artist: "Artist", title: title, stage: .failed)
            let detail = """
            {"event":"progress","stage":"metadata","message":"Resolving recording metadata"}
            {"event":"progress","stage":"download","message":"Downloading audio"}
            {"event":"progress","stage":"tag","message":"Writing tags"}
            Error: approved artwork URL did not return a recognized image
            """
            track.errorDetail = detail

            let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

            XCTAssertEqual(presentation.statusLabel, "File save failed")
            XCTAssertEqual(presentation.summary, "The artwork link did not return a usable image.")
            XCTAssertTrue(presentation.recovery.contains("Add Music"))
            XCTAssertTrue(presentation.recovery.contains("approve this recording again"))
            XCTAssertEqual(presentation.technicalDetail, detail)
        }
    }

    func testUnknownFailureShowsTheReportedReasonWithoutClaimingADiagnosis() throws {
        var track = TrackRequest(artist: "Artist", title: "Title", stage: .failed)
        track.errorDetail = "{\"event\":\"progress\",\"stage\":\"download\"}\nError: provider rejected the request"

        let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

        XCTAssertEqual(presentation.summary, "provider rejected the request")
        XCTAssertFalse(presentation.summary.contains("progress"))
        XCTAssertTrue(presentation.recovery.contains("review"))
    }

    func testMissingReasonUsesAnHonestFallback() throws {
        for detail in [nil, "", "   \n", "{\"event\":\"progress\",\"stage\":\"tag\"}"] as [String?] {
            var track = TrackRequest(artist: "Artist", title: "Title", stage: .failed)
            track.errorDetail = detail

            let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

            XCTAssertEqual(presentation.summary, "Needle could not finish saving this recording. No failure reason was recorded.")
            XCTAssertEqual(presentation.statusLabel, "File save failed")
        }
    }

    func testSpotifyFailureKeepsSavedFileAndDeliveryFailureDistinct() throws {
        var track = TrackRequest(artist: "Artist", title: "Title", savedPath: "/tmp/track.mp3",
                                 spotifyStatus: .failed, spotifyJobID: "existing-job", stage: .saved)
        track.errorDetail = "Your file is saved. Spotify delivery needs attention: Spotify is not running."

        let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

        XCTAssertEqual(presentation.statusLabel, "File saved · Spotify needs attention")
        XCTAssertEqual(presentation.summary, "Spotify is not running.")
        XCTAssertTrue(presentation.recovery.contains("Check Spotify"))
        XCTAssertEqual(presentation.technicalDetail, track.errorDetail)
    }

    func testSpotifyFailureWithoutReceiptUsesTheAvailableDeliveryAction() throws {
        let track = TrackRequest(artist: "Artist", title: "Title", savedPath: "/tmp/track.mp3",
                                 spotifyStatus: .failed, stage: .saved)

        let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

        XCTAssertEqual(presentation.summary, "Spotify delivery failed. No failure reason was recorded.")
        XCTAssertTrue(presentation.recovery.contains("Add to Spotify"))
        XCTAssertNil(presentation.technicalDetail)
    }

    func testFailureAfterSavingDoesNotTellTheUserToDownloadAgain() throws {
        var track = TrackRequest(artist: "Artist", title: "Title", savedPath: "/tmp/track.mp3", stage: .failed)
        track.errorDetail = "Unable to finish the operation."

        let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

        XCTAssertEqual(presentation.statusLabel, "File saved · Needs attention")
        XCTAssertTrue(presentation.recovery.contains("Library"))
        XCTAssertFalse(presentation.recovery.contains("approve"))
    }

    func testKeptFileWithMissingPathRequiresLibraryReviewBeforeAnotherSave() throws {
        var track = TrackRequest(artist: "Artist", title: "Title", stage: .failed)
        track.errorDetail = "The returned recording differs from your approved source. Your file was kept; review its details."

        let presentation = try XCTUnwrap(ActivityFailurePresentation(track: track))

        XCTAssertEqual(presentation.statusLabel, "Save needs review")
        XCTAssertTrue(presentation.summary.contains("Your file was kept"))
        XCTAssertTrue(presentation.recovery.contains("Library"))
        XCTAssertTrue(presentation.recovery.contains("before approving another save"))
        XCTAssertFalse(presentation.recovery.contains("approve this recording again"))
        XCTAssertEqual(presentation.technicalDetail, track.errorDetail)
    }

    func testSuccessfulAndPendingTracksDoNotAcquireAFailurePresentation() {
        for stage in [JobStage.saved, .spotifyAdded, .spotifyPending, .tag, .cancelled] {
            var track = TrackRequest(artist: "Artist", title: "Title", stage: stage)
            track.errorDetail = "An informational detail."
            XCTAssertNil(ActivityFailurePresentation(track: track))
        }
    }
}
