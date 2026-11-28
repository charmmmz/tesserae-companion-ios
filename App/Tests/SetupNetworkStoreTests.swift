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
        let store = SetupNetworkStore(defaults: defaults, credentials: credentials)

        try await store.record(ssid: "Home WiFi", password: "secret", savePassword: true)

        XCTAssertEqual(store.networks.map(\.ssid), ["Home WiFi"])
        XCTAssertEqual(store.networks.first?.hasSavedPassword, true)
        let firstPassword = try await store.savedPassword(ssid: "Home WiFi")
        XCTAssertEqual(firstPassword, "secret")

        try await store.record(ssid: "Home WiFi", password: "replacement", savePassword: false)
        XCTAssertEqual(store.networks.first?.hasSavedPassword, false)
        let removedPassword = try await store.savedPassword(ssid: "Home WiFi")
        XCTAssertNil(removedPassword)
    }

    func testMergesLegacyNetworksAndForgettingRemovesAllCredentials() async throws {
        let suiteName = "SetupNetworkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        let store = SetupNetworkStore(defaults: defaults, credentials: credentials)

        let home = SetupKnownNetwork(ssid: "Home", lastUsedAt: Date(timeIntervalSince1970: 100), hasSavedPassword: true)
        let studio = SetupKnownNetwork(ssid: "Studio", lastUsedAt: Date(timeIntervalSince1970: 200), hasSavedPassword: true)
        let encoder = JSONEncoder()
        defaults.set(try encoder.encode([home]), forKey: "device-setup.networks.home")
        defaults.set(try encoder.encode([studio, home]), forKey: "device-setup.networks.studio")
        let legacyHome = "old-home.\(Data(home.ssid.utf8).base64EncodedString())"
        let studioHome = "studio.\(Data(home.ssid.utf8).base64EncodedString())"
        try await credentials.save(token: "same", for: legacyHome)
        try await credentials.save(token: "same", for: studioHome)
        try await credentials.save(token: "studio", for: "studio.\(Data(studio.ssid.utf8).base64EncodedString())")

        try await store.load(aliases: ["home": "old-home"])
        XCTAssertEqual(store.networks, [studio, home])
        let migratedPassword = try await store.savedPassword(ssid: home.ssid)
        XCTAssertEqual(migratedPassword, "same")

        try await store.remove(ssid: home.ssid)
        let oldPassword = try await credentials.token(for: legacyHome)
        let duplicate = try await credentials.token(for: studioHome)
        XCTAssertNil(oldPassword)
        XCTAssertNil(duplicate)

        let restarted = SetupNetworkStore(defaults: defaults, credentials: credentials)
        try await restarted.load()
        XCTAssertEqual(restarted.networks, [studio])
        let forgotten = try await restarted.savedPassword(ssid: home.ssid)
        XCTAssertNil(forgotten)
    }

    func testConflictingLegacyPasswordsRequireEnteringPasswordAgain() async throws {
        let suiteName = "SetupNetworkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let credentials = InMemoryCredentialStore()
        let store = SetupNetworkStore(defaults: defaults, credentials: credentials)
        let network = SetupKnownNetwork(ssid: "Shared Name", lastUsedAt: Date(), hasSavedPassword: true)
        let entries = try JSONEncoder().encode([network])
        let suffix = Data(network.ssid.utf8).base64EncodedString()
        for server in ["a", "b"] {
            defaults.set(entries, forKey: "device-setup.networks.\(server)")
            try await credentials.save(token: server, for: "\(server).\(suffix)")
        }

        try await store.load()
        XCTAssertEqual(store.networks.map(\.ssid), [network.ssid])
        XCTAssertEqual(store.networks.first?.hasSavedPassword, false)
        let password = try await store.savedPassword(ssid: network.ssid)
        XCTAssertNil(password)
    }
}
