import Foundation

public struct SavedConnection: Codable, Sendable, Identifiable {
    public let identity: ConnectionIdentity
    public let name: String
    public let localInstance: TesseraeInstance?
    public let legacyInstanceID: String?
    public var id: ConnectionID { identity.id }

    public init(identity: ConnectionIdentity, name: String, localInstance: TesseraeInstance? = nil,
                legacyInstanceID: String? = nil) {
        self.identity = identity
        self.name = name
        self.localInstance = localInstance
        self.legacyInstanceID = legacyInstanceID
    }
}

public struct ConnectionRegistry: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory.appending(path: "Connections") }

    public func savedConnections() throws -> [SavedConnection] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "connection" }
            .map { try ConnectionCoding.decoder().decode(SavedConnection.self, from: Data(contentsOf: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ connection: SavedConnection) throws {
        try SharedFileLock(url: directory.appending(path: "registry.lock")).withLock {
            try writeProtected(connection, to: descriptorURL(connection.id))
        }
    }

    public func connection(_ id: ConnectionID) throws -> SavedConnection? {
        let url = descriptorURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try ConnectionCoding.decoder().decode(SavedConnection.self, from: Data(contentsOf: url))
        guard value.id == id else { throw ConnectionError.invalidIdentity }
        return value
    }

    public func selectedID() throws -> ConnectionID? {
        let url = directory.appending(path: "selection.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try ConnectionCoding.decoder().decode(Selection.self, from: Data(contentsOf: url)).id
    }

    public func select(_ id: ConnectionID?) throws {
        try SharedFileLock(url: directory.appending(path: "registry.lock")).withLock {
            if let id, try connection(id) == nil { throw ConnectionError.invalidIdentity }
            try writeProtected(Selection(id: id), to: directory.appending(path: "selection.json"))
        }
    }

    public func clearSelection(ifMatching id: ConnectionID) throws {
        try SharedFileLock(url: directory.appending(path: "registry.lock")).withLock {
            guard try selectedID() == id else { return }
            try writeProtected(Selection(id: nil), to: directory.appending(path: "selection.json"))
        }
    }

    func snapshotURL(_ id: ConnectionID) -> URL { directory.appending(path: "\(id.fileComponent)/snapshot.json") }
    func receiptDirectory(_ id: ConnectionID) -> URL { directory.appending(path: "\(id.fileComponent)/receipts") }
    private func descriptorURL(_ id: ConnectionID) -> URL { directory.appending(path: id.fileComponent + ".connection") }
    private struct Selection: Codable { let id: ConnectionID? }
}

public struct ConnectionStateStore: CompanionStateStoring {
    public let registry: ConnectionRegistry
    private let sessions: SharedSessionStore
    private let legacy: any CompanionStateStoring
    private let legacyCredentials: any CredentialStoring
    private let isPrimary: Bool
    private let suiteName: String?

    public init(registry: ConnectionRegistry, sessions: SharedSessionStore, legacy: any CompanionStateStoring,
                legacyCredentials: any CredentialStoring, isPrimary: Bool, suiteName: String? = nil) {
        self.registry = registry
        self.sessions = sessions
        self.legacy = legacy
        self.legacyCredentials = legacyCredentials
        self.isPrimary = isPrimary
        self.suiteName = suiteName
    }

    public func load() async throws -> CompanionSnapshot? {
        try await migrateIfNeeded()
        guard let id = try registry.selectedID(), let connection = try registry.connection(id),
              connection.localInstance != nil else { return nil }
        return try await load(for: id)
    }

    public func load(for id: ConnectionID) async throws -> CompanionSnapshot? {
        guard let fence = try await sessions.fence(for: id) else { return nil }
        return try await sessions.commit(fence) {
            try SharedFileLock(url: registry.directory.appending(path: "\(id.fileComponent).snapshot.lock")).withLock {
                let url = registry.snapshotURL(id)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    guard let instance = try registry.connection(id)?.localInstance else { return nil }
                    return CompanionSnapshot(activeInstance: instance, capabilities: nil, displays: [], dashboards: [], jobs: [],
                                             connectionFence: fence)
                }
                let snapshot = try ConnectionCoding.decoder().decode(CompanionSnapshot.self, from: Data(contentsOf: url))
                guard snapshot.connectionFence == fence,
                      snapshot.activeInstance.connectionIdentity.id == id else { throw ConnectionError.sessionChanged }
                let incoming = try receipts(for: id, fence: fence)
                return CompanionSnapshot(activeInstance: snapshot.activeInstance, capabilities: snapshot.capabilities,
                    displays: snapshot.displays, dashboards: snapshot.dashboards, lineups: snapshot.lineups,
                    jobs: CompanionSnapshot.mergingJobs(current: snapshot.jobs, incoming: incomingJobs(incoming, snapshot: snapshot)),
                    activityClearedBefore: snapshot.activityClearedBefore, updatedAt: snapshot.updatedAt,
                    connectionFence: fence)
            }
        }
    }

    public func save(_ snapshot: CompanionSnapshot) async throws {
        guard let fence = snapshot.connectionFence,
              fence.connectionID == snapshot.activeInstance.connectionIdentity.id else { throw ConnectionError.invalidIdentity }
        try await sessions.commit(fence) {
            if !isPrimary {
                try writeProtected(Receipt(fence: fence, jobs: snapshot.jobs),
                    to: registry.receiptDirectory(fence.connectionID).appending(path: UUID().uuidString + ".json"))
                return
            }
            let id = fence.connectionID
            try SharedFileLock(url: registry.directory.appending(path: "\(id.fileComponent).snapshot.lock")).withLock {
            let incoming = try receipts(for: id, fence: fence)
            let merged = CompanionSnapshot(activeInstance: snapshot.activeInstance, capabilities: snapshot.capabilities,
                displays: snapshot.displays, dashboards: snapshot.dashboards, lineups: snapshot.lineups,
                jobs: CompanionSnapshot.mergingJobs(current: snapshot.jobs, incoming: incomingJobs(incoming, snapshot: snapshot)),
                activityClearedBefore: snapshot.activityClearedBefore, connectionFence: fence)
            try writeProtected(merged, to: registry.snapshotURL(id))
            // Receipts are immutable. A concurrent writer's new UUID is not in this captured list.
            for receipt in incoming { try FileManager.default.removeItem(at: receipt.url!) }
            }
        }
    }

    public func clear() async throws {
        guard isPrimary else { return }
        try registry.select(nil)
    }

    private func migrateIfNeeded() async throws {
        let marker = registry.directory.appending(path: "legacy-import.json")
        if FileManager.default.fileExists(atPath: marker.path) { return }
        guard let old = try await legacy.load() else {
            try SharedFileLock(url: registry.directory.appending(path: "migration.lock")).withLock {
                if !FileManager.default.fileExists(atPath: marker.path) { try writeProtected(["complete": true], to: marker) }
            }
            return
        }
        guard let token = try await legacyCredentials.token(for: old.activeInstance.id) else {
            if FileManager.default.fileExists(atPath: marker.path) { return }
            throw ConnectionError.authorizationRequired
        }
        let fence = try await sessions.importLocal(instance: old.activeInstance, token: token)
        try await sessions.validate(fence)
        let connection = SavedConnection(identity: old.activeInstance.connectionIdentity, name: old.activeInstance.name,
            localInstance: old.activeInstance, legacyInstanceID: old.activeInstance.id)
        try SharedFileLock(url: registry.directory.appending(path: "migration.lock")).withLock {
            guard !FileManager.default.fileExists(atPath: marker.path) else { return }
            try registry.save(connection)
            try writeProtected(old.binding(fence), to: registry.snapshotURL(connection.id))
            try LegacyConnectionMigration.migrate(directory: registry.directory.deletingLastPathComponent(),
                suiteName: suiteName, instance: old.activeInstance, fence: fence)
            try registry.select(connection.id)
            try writeProtected(["connectionID": connection.id.rawValue], to: marker)
        }
        // The new readers no longer use these keys. Failures leave recoverable input, never erase the new session.
        try await legacyCredentials.removeToken(for: old.activeInstance.id)
        try await legacy.clear()
    }

    private struct Receipt: Codable {
        let fence: ConnectionFence
        let jobs: [PushJob]
        var url: URL? = nil
        enum CodingKeys: String, CodingKey { case fence, jobs }
    }

    private func receipts(for id: ConnectionID, fence: ConnectionFence) throws -> [Receipt] {
        let directory = registry.receiptDirectory(id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { url in
                var receipt = try ConnectionCoding.decoder().decode(Receipt.self, from: Data(contentsOf: url))
                guard receipt.fence == fence else { return nil }
                receipt.url = url
                return receipt
            }
    }

    private func incomingJobs(_ receipts: [Receipt], snapshot: CompanionSnapshot) -> [PushJob] {
        receipts.flatMap(\.jobs).filter { job in
            snapshot.activityClearedBefore.map { job.createdAt > $0 } ?? true
        }
    }
}
