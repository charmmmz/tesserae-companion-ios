import XCTest
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
final class SetupNetworkStoreTests: XCTestCase {
    func testRecordsNamesAndStoresPasswordsOnlyWhenRequested() async throws {
        let suiteName = "SetupNetworkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        let store = SetupNetworkStore(
            defaults: defaults,
            credentials: credentials
        )

        try await store.record(
            instanceID: "home",
            ssid: "Home WiFi",
            password: "secret",
            savePassword: true
        )

        XCTAssertEqual(store.networks.map(\.ssid), ["Home WiFi"])
        XCTAssertEqual(store.networks.first?.hasSavedPassword, true)
        let firstPassword = try await store.savedPassword(
            instanceID: "home",
            ssid: "Home WiFi"
        )
        XCTAssertEqual(firstPassword, "secret")

        try await store.record(
            instanceID: "home",
            ssid: "Home WiFi",
            password: "replacement",
            savePassword: false
        )
        XCTAssertEqual(store.networks.first?.hasSavedPassword, false)
        let removedPassword = try await store.savedPassword(
            instanceID: "home",
            ssid: "Home WiFi"
        )
        XCTAssertNil(removedPassword)
    }

    func testHistoryIsPerServerAndForgetRemovesItsKeychainEntry() async throws {
        let suiteName = "SetupNetworkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        let store = SetupNetworkStore(
            defaults: defaults,
            credentials: credentials
        )
        try await store.record(
            instanceID: "home",
            ssid: "Home WiFi",
            password: "secret",
            savePassword: true
        )
        try await store.record(
            instanceID: "studio",
            ssid: "Studio WiFi",
            password: "studio-secret",
            savePassword: true
        )

        store.load(instanceID: "home")
        XCTAssertEqual(store.networks.map(\.ssid), ["Home WiFi"])

        try await store.remove(instanceID: "home", ssid: "Home WiFi")
        XCTAssertTrue(store.networks.isEmpty)
        let homePassword = try await store.savedPassword(
            instanceID: "home",
            ssid: "Home WiFi"
        )
        let studioPassword = try await store.savedPassword(
            instanceID: "studio",
            ssid: "Studio WiFi"
        )
        XCTAssertNil(homePassword)
        XCTAssertEqual(studioPassword, "studio-secret")
    }
}
