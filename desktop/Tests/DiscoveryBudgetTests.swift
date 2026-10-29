import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryBudgetTests: XCTestCase {
    func testCatalogBudgetIsSharedAcrossSelectedArtists() {
        for artistCount in 1...5 {
            let limit = DiscoveryStore.candidateLimit(artistCount: artistCount)
            XCTAssertGreaterThan(limit, 0)
            XCTAssertLessThanOrEqual(limit * artistCount, 45)
        }
        XCTAssertEqual(DiscoveryStore.candidateLimit(artistCount: 1), 45)
        XCTAssertEqual(DiscoveryStore.candidateLimit(artistCount: 5), 9)
    }
}
