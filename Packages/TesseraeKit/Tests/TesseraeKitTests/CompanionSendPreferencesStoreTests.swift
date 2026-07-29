import XCTest
@testable import TesseraeKit

final class CompanionSendPreferencesStoreTests: XCTestCase {
    func testNormalizesAndKeepsPreferencesPerInstance() async throws {
        let store = InMemoryCompanionSendPreferencesStore()
        await store.save(
            CompanionSendPreferences(
                instanceID: "home",
                deviceIDs: ["kitchen", "bedroom", "kitchen"],
                imageFitMode: .blur
            )
        )
        await store.save(
            CompanionSendPreferences(
                instanceID: "studio",
                deviceIDs: ["desk"],
                imageFitMode: .center
            )
        )

        let home = await store.preferences(for: "home")
        let studio = await store.preferences(for: "studio")
        XCTAssertEqual(home?.deviceIDs, ["bedroom", "kitchen"])
        XCTAssertEqual(home?.imageFitMode, .blur)
        XCTAssertEqual(studio?.deviceIDs, ["desk"])
    }

    func testUserDefaultsStoreRoundTripsAndRemovesOneInstance() async throws {
        let suiteName = "CompanionSendPreferencesStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = UserDefaultsCompanionSendPreferencesStore(
            suiteName: suiteName
        )
        let expected = CompanionSendPreferences(
            instanceID: "home",
            deviceIDs: ["frame"],
            imageFitMode: .fill
        )

        try await store.save(expected)
        let loaded = try await store.preferences(for: expected.instanceID)
        XCTAssertEqual(loaded, expected)

        try await store.removePreferences(for: expected.instanceID)
        let removed = try await store.preferences(for: expected.instanceID)
        XCTAssertNil(removed)
    }
}
