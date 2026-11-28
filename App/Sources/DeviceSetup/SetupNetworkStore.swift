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
    private static let legacyPrefix = "device-setup.networks."
    private static let sharedKey = "device-setup.shared-networks.v1"

    private let defaults: UserDefaults
    private let credentials: any CredentialStoring
    private var migration: Task<Void, Error>?
    private var pendingWrite: Task<Void, Never>?
    private var legacyAliases: [String: String] = [:]
    private(set) var networks: [SetupKnownNetwork] = []

    init(defaults: UserDefaults = .standard, credentials: any CredentialStoring) {
        self.defaults = defaults
        self.credentials = credentials
    }

    func load(aliases: [String: String] = [:]) async throws {
        legacyAliases.merge(aliases) { _, current in current }
        if let migration { return try await migration.value }
        if let data = defaults.data(forKey: Self.sharedKey) {
            networks = try JSONDecoder().decode([SetupKnownNetwork].self, from: data)
            return
        }
        let migration = Task { try await migrateLegacyNetworks() }
        self.migration = migration
        defer { self.migration = nil }
        try await migration.value
    }

    func savedPassword(ssid: String) async throws -> String? {
        await pendingWrite?.value
        try await load()
        guard networks.contains(where: { $0.ssid == ssid && $0.hasSavedPassword }) else { return nil }
        return try await credentials.token(for: credentialKey(ssid))
    }

    func record(ssid: String, password: String, savePassword: Bool) async throws {
        try await write {
            try await self.load()
            if savePassword {
                try await self.credentials.save(token: password, for: self.credentialKey(ssid))
            } else {
                try await self.removePasswords(for: ssid)
            }
            let entry = SetupKnownNetwork(ssid: ssid, lastUsedAt: Date(), hasSavedPassword: savePassword)
            try self.persist([entry] + self.networks.filter { $0.ssid != ssid })
        }
    }

    func remove(ssid: String) async throws {
        try await write {
            try await self.load()
            try await self.removePasswords(for: ssid)
            try self.persist(self.networks.filter { $0.ssid != ssid })
        }
    }

    private func write(_ update: @escaping @MainActor () async throws -> Void) async throws {
        let previous = pendingWrite
        let task = Task {
            await previous?.value
            try await update()
        }
        pendingWrite = Task { _ = await task.result }
        try await task.value
    }

    private func migrateLegacyNetworks() async throws {
        var history: [String: Date] = [:]
        var passwords: [String: Set<String>] = [:]
        for (id, entries) in legacyNetworks() {
            for entry in entries {
                history[entry.ssid] = max(history[entry.ssid] ?? .distantPast, entry.lastUsedAt)
                guard entry.hasSavedPassword else { continue }
                for key in legacyCredentialKeys(id: id, ssid: entry.ssid) {
                    if let password = try await credentials.token(for: key) {
                        passwords[entry.ssid, default: []].insert(password)
                    }
                }
            }
        }
        var migrated: [SetupKnownNetwork] = []
        for (ssid, date) in history {
            let candidates = passwords[ssid] ?? []
            let password = candidates.count == 1 ? candidates.first : nil
            let key = credentialKey(ssid)
            if let password {
                try await credentials.save(token: password, for: key)
                guard try await credentials.token(for: key) == password else {
                    throw CocoaError(.fileWriteUnknown)
                }
            } else {
                try await credentials.removeToken(for: key)
            }
            migrated.append(.init(ssid: ssid, lastUsedAt: date, hasSavedPassword: password != nil))
        }
        try persist(migrated.sorted {
            $0.lastUsedAt == $1.lastUsedAt ? $0.ssid < $1.ssid : $0.lastUsedAt > $1.lastUsedAt
        })
    }

    private func persist(_ updated: [SetupKnownNetwork]) throws {
        defaults.set(try JSONEncoder().encode(updated), forKey: Self.sharedKey)
        networks = updated
    }

    private func legacyNetworks() -> [(String, [SetupKnownNetwork])] {
        defaults.dictionaryRepresentation().compactMap { key, value in
            guard key.hasPrefix(Self.legacyPrefix), let data = value as? Data,
                  let entries = try? JSONDecoder().decode([SetupKnownNetwork].self, from: data) else { return nil }
            return (String(key.dropFirst(Self.legacyPrefix.count)), entries)
        }
    }

    private func removePasswords(for ssid: String) async throws {
        for (id, entries) in legacyNetworks() where entries.contains(where: { $0.ssid == ssid }) {
            for key in legacyCredentialKeys(id: id, ssid: ssid) {
                try await credentials.removeToken(for: key)
            }
        }
        try await credentials.removeToken(for: credentialKey(ssid))
    }

    private func legacyCredentialKeys(id: String, ssid: String) -> Set<String> {
        let suffix = Data(ssid.utf8).base64EncodedString()
        var keys: Set<String> = ["\(id).\(suffix)"]
        if let alias = legacyAliases[id] { keys.insert("\(alias).\(suffix)") }
        return keys
    }

    private func credentialKey(_ ssid: String) -> String {
        "shared:\(Data(ssid.utf8).base64EncodedString())"
    }
}
