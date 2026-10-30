import XCTest
@testable import NeedleDesktop

final class AddMusicRequestTests: XCTestCase {
    func testSourceLinkAloneCanFindRecordings() {
        let request = AddMusicRequest(artist: "", title: "", sourceURL: " https://example.com/watch?v=literal&list=keep \n")
        XCTAssertTrue(request.canSearch)
        XCTAssertTrue(request.needsIdentification)
        XCTAssertEqual(request.sourceURL, "https://example.com/watch?v=literal&list=keep")
    }

    func testInvalidSourceCannotStartSearchEvenWithIdentity() {
        for source in ["file:///tmp/song.mp3", "javascript:alert(1)", "https://", "not a link", "https://user:password@" + "example.com/source"] {
            XCTAssertFalse(AddMusicRequest(artist: "Artist", title: "Song", sourceURL: source).canSearch)
        }
    }

    func testTextSearchRequiresBothIdentityFields() {
        XCTAssertTrue(AddMusicRequest(artist: " Artist ", title: " Song ", sourceURL: "").canSearch)
        XCTAssertFalse(AddMusicRequest(artist: "Artist", title: " \n", sourceURL: "").canSearch)
    }

    func testDetectedIdentityFillsOnlyMissingFields() {
        let request = AddMusicRequest(artist: "My artist", title: "", sourceURL: "https://example.com/source")
        let resolved = request.identifying(artist: "Detected artist", title: " Detected song ")
        XCTAssertEqual(resolved.artist, "My artist")
        XCTAssertEqual(resolved.title, "Detected song")
        XCTAssertEqual(resolved.sourceURL, request.sourceURL)
        XCTAssertFalse(resolved.needsIdentification)
    }

    func testIncompleteIdentityStillNeedsInput() {
        let request = AddMusicRequest(artist: "", title: "", sourceURL: "https://example.com/source")
        XCTAssertTrue(request.identifying(artist: nil, title: "Song").needsIdentification)
    }
}
