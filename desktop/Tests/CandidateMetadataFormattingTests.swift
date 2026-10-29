import XCTest
@testable import NeedleDesktop

final class CandidateMetadataFormattingTests: XCTestCase {
    func testBitrateIsExplicitAndUnknownWhenSourceDidNotReportIt() {
        XCTAssertEqual(CandidateMetadataFormatting.bitrate(160), "160 kbps")
        XCTAssertEqual(CandidateMetadataFormatting.bitrate(nil), "Unknown")
        XCTAssertEqual(CandidateMetadataFormatting.bitrate(0), "Unknown")
    }

    func testViewsUseReadableCompactUnitsWithoutInventingMissingValues() {
        XCTAssertEqual(CandidateMetadataFormatting.views(nil), "Unknown")
        XCTAssertEqual(CandidateMetadataFormatting.views(999), "999")
        XCTAssertEqual(CandidateMetadataFormatting.views(1_250), "1.3K")
        XCTAssertEqual(CandidateMetadataFormatting.views(2_000_000), "2M")
        XCTAssertEqual(CandidateMetadataFormatting.views(3_400_000_000), "3.4B")
    }

    func testSearchResponseDecodesSourceFactsReportedByRust() throws {
        let data = Data(#"{"ok":true,"request":{"artist":"Artist","title":"Title"},"metadata":null,"candidates":[{"candidate":{"provider":"youtube","id":"abc","url":"https://youtube.com/watch?v=abc","title":"Title","uploader":"Uploader","duration_ms":180000,"thumbnail_url":null,"view_count":1250000,"audio_codec":"opus","audio_bitrate_kbps":160},"score":{"confidence":0.9,"status":"recommended","positives":[],"warnings":[],"rejects":[]}}]}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(SearchResponse.self, data: data)
        let candidate = try XCTUnwrap(response.candidates.first?.candidate)
        XCTAssertEqual(candidate.viewCount, 1_250_000)
        XCTAssertEqual(candidate.audioCodec, "opus")
        XCTAssertEqual(candidate.audioBitrateKbps, 160)
    }
    func testSearchResponseDecodesVerifiedChannel() throws {
        let data = Data(#"{"ok":true,"request":{"artist":"The Weeknd","title":"Wanderlust"},"metadata":null,"candidates":[{"candidate":{"provider":"youtube","id":"abc","url":"https://youtube.com/watch?v=abc","title":"Wanderlust","uploader":"The Weeknd","channel_is_verified":true,"duration_ms":307000,"thumbnail_url":null},"score":{"confidence":60,"status":"uncertain","positives":[],"warnings":[],"rejects":[]}}]}"#.utf8)
        let response = try NeedleCLIService.parseLastJSON(SearchResponse.self, data: data)
        XCTAssertEqual(response.candidates.first?.candidate.channelIsVerified, true)
    }

}
