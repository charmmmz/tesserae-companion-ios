import Foundation
import Observation
import TesseraeKit

struct SetupKnownNetwork: Codable, Identifiable, Equatable, Sendable {
    var id: String { ssid }
    let ssid: String
    let lastUsedAt: Date
    let hasSavedPassword: Bool
}

@MainActor
@Observable
final class SetupNetworkStore {
    private static let defaultsKeyPrefix = "device-setup.networks."

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring
    private(set) var networks: [SetupKnownNetwork] = []
    private var loadedInstanceID: String?

    init(
        defaults: UserDefaults = .standard,
        credentials: any CredentialStoring
    ) {
        self.defaults = defaults
        self.credentials = credentials
    }

    func load(instanceID: String) {
        loadedInstanceID = instanceID
        guard
            let data = defaults.data(
                forKey: Self.defaultsKeyPrefix + instanceID
            ),
            let decoded = try? JSONDecoder().decode(
                [SetupKnownNetwork].self,
                from: data
            )
        else {
            networks = []
            return
        }
        networks = decoded.sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    func savedPassword(instanceID: String, ssid: String) async throws -> String? {
        try await credentials.token(for: credentialKey(
            instanceID: instanceID,
            ssid: ssid
        ))
    }

    func record(
        instanceID: String,
        ssid: String,
        password: String,
        savePassword: Bool
    ) async throws {
        let key = credentialKey(instanceID: instanceID, ssid: ssid)
        if savePassword {
            try await credentials.save(token: password, for: key)
        } else {
            try await credentials.removeToken(for: key)
        }

        if loadedInstanceID != instanceID { load(instanceID: instanceID) }
        networks.removeAll { $0.ssid == ssid }
        networks.insert(
            SetupKnownNetwork(
                ssid: ssid,
                lastUsedAt: Date(),
                hasSavedPassword: savePassword
            ),
            at: 0
        )
        // Network history is a convenience list, not an audit log.
        networks = Array(networks.prefix(12))
        if let data = try? JSONEncoder().encode(networks) {
            defaults.set(data, forKey: Self.defaultsKeyPrefix + instanceID)
        }
    }

    func remove(instanceID: String, ssid: String) async throws {
        try await credentials.removeToken(for: credentialKey(
            instanceID: instanceID,
            ssid: ssid
        ))
        if loadedInstanceID != instanceID { load(instanceID: instanceID) }
        networks.removeAll { $0.ssid == ssid }
        if let data = try? JSONEncoder().encode(networks) {
            defaults.set(data, forKey: Self.defaultsKeyPrefix + instanceID)
        }
    }

    private func credentialKey(instanceID: String, ssid: String) -> String {
        "\(instanceID).\(Data(ssid.utf8).base64EncodedString())"
    }
}
