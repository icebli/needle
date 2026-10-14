import XCTest
@testable import NeedleDesktop

@MainActor
final class DiscoveryStoreTests: XCTestCase {
    func testLegacyEmptySnapshotDoesNotPretendSearchCompleted() throws {
        let suite = "NeedleDiscoveryStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "artists": [], "recordings": [], "lastSynced": NSNull(),
        ]), forKey: "needle.discovery")

        let store = DiscoveryStore(defaults: defaults)
        XCTAssertFalse(store.hasSearched)
        XCTAssertTrue(store.warnings.isEmpty)
        XCTAssertNil(store.error)
    }

    func testCompletedEmptySnapshotRestoresSearchStateWarningsAndError() throws {
        let suite = "NeedleDiscoveryStoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try JSONSerialization.data(withJSONObject: [
            "artists": [], "recordings": [], "lastSynced": NSNull(),
            "hasSearched": true,
            "warnings": ["YouTube search timed out."],
            "error": "Couldn’t search Drake. Check the source setup and try again.",
        ]), forKey: "needle.discovery")

        let store = DiscoveryStore(defaults: defaults)
        XCTAssertTrue(store.hasSearched)
        XCTAssertEqual(store.warnings, ["YouTube search timed out."])
        XCTAssertEqual(store.error, "Couldn’t search Drake. Check the source setup and try again.")
    }
}
