import Foundation
import Testing
@testable import TesseraeKit

@Suite struct ConnectionRegistryTests {
    private func fixture(transport: any TesseraeHTTPTransporting = URLSessionTesseraeTransport()) -> (ConnectionRuntime, InMemoryCredentialStore, InMemoryCompanionStateStore, URL, String) {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let credentials = InMemoryCredentialStore()
        let legacy = InMemoryCompanionStateStore()
        let sessions = SharedSessionStore(directory: root, vault: TestSessionVault(directory: root.appending(path: "vault")), transport: transport)
        let suite = "ConnectionRegistryTests.\(UUID())"
        let runtime = ConnectionRuntime(directory: root, identity: TesseraeClientIdentity(appVersion: "test", installationID: "test"),
            credentials: credentials, sessions: sessions, legacy: legacy, isPrimary: true, transport: transport, suiteName: suite)
        return (runtime, credentials, legacy, root, suite)
    }

    private func instance(id: String = UUID().uuidString, host: String = "one.local") -> TesseraeInstance {
        TesseraeInstance(id: id, name: host, baseURL: URL(string: "http://\(host):8765")!,
            serverVersion: "0.500", timezone: "UTC", webURL: "http://\(host):8765")
    }

    @Test func importsLegacySnapshotCredentialQueueAndPreferencesWithoutRepairingState() async throws {
        let (runtime, credentials, legacy, root, suite) = fixture()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let instance = instance()
        let snapshot = CompanionSnapshot(activeInstance: instance, capabilities: nil, displays: [], dashboards: [], jobs: [])
        await legacy.save(snapshot)
        await credentials.save(token: "synthetic-local", for: instance.id)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let task = SharedImageRequest(instanceID: instance.id, fileName: "synthetic.jpg", contentType: "image/jpeg",
            fit: .fit, deviceIDs: ["same-resource-id"], idempotencyKey: "preserve-key", createdAt: created,
            updatedAt: created, status: .submitting)
        let queue = FileShareQueueStore(directoryURL: root)
        try await queue.enqueue(imageData: Data([1, 2]), request: task)
        let shared = try #require(UserDefaults(suiteName: suite))
        shared.set(try TesseraeJSON.encoder().encode([instance.id: CompanionSendPreferences(instanceID: instance.id,
            deviceIDs: ["same-resource-id"], imageFitMode: .fit)]), forKey: "TesseraeCompanionSendPreferences")
        let restored = try #require(try await runtime.stateStore.load())
        let fence = try #require(restored.connectionFence)
        #expect(restored.activeInstance == instance)
        #expect(try await runtime.sessions.authorization(for: fence).token == "synthetic-local")
        #expect(await credentials.token(for: instance.id) == nil)
        #expect(await legacy.load() == nil)
        let requests = try await queue.requests()
        let migrated = try #require(requests.first)
        #expect(migrated.instanceID == instance.storageID)
        #expect(migrated.connectionEpoch == fence.epoch)
        #expect(migrated.id == task.id && migrated.idempotencyKey == "preserve-key")
        #expect(migrated.createdAt == created && migrated.status == .submitting)
        let prefs = UserDefaultsCompanionSendPreferencesStore(suiteName: suite, directoryURL: root)
        #expect(try await prefs.preferences(for: instance.storageID)?.deviceIDs == ["same-resource-id"])
        #expect(try await runtime.stateStore.load()?.connectionFence == fence)
    }

    @Test func savedConnectionsKeepIndependentSnapshotsAndDoNotRevokeOnSelection() async throws {
        let (runtime, credentials, legacy, _, _) = fixture()
        let one = instance(id: "same", host: "one.local")
        await credentials.save(token: "one", for: one.id)
        await legacy.save(CompanionSnapshot(activeInstance: one, capabilities: nil, displays: [], dashboards: [], jobs: []))
        let first = try #require(try await runtime.stateStore.load())
        let second = instance(id: "same", host: "two.local")
        let secondFence = try await runtime.sessions.installLocal(instance: second, token: "two")
        try runtime.registry.save(SavedConnection(identity: second.connectionIdentity, name: second.name, localInstance: second))
        try await runtime.stateStore.save(CompanionSnapshot(activeInstance: second, capabilities: nil,
            displays: [], dashboards: [], jobs: [], connectionFence: secondFence))
        try await runtime.activate(second.connectionIdentity.id)
        #expect(try await runtime.stateStore.load()?.activeInstance == second)
        try await runtime.activate(one.connectionIdentity.id)
        #expect(try await runtime.stateStore.load()?.activeInstance == one)
        #expect(try await runtime.sessions.authorization(for: #require(first.connectionFence)).token == "one")
        #expect(try runtime.registry.savedConnections().count == 2)
    }

    @Test func cloudSelectionCannotReturnOldLocalSnapshotOrUseBareResourceID() async throws {
        let (runtime, credentials, legacy, _, _) = fixture()
        let local = instance()
        await credentials.save(token: "local", for: local.id)
        await legacy.save(CompanionSnapshot(activeInstance: local, capabilities: nil, displays: [], dashboards: [], jobs: []))
        _ = try await runtime.stateStore.load()
        let cloud = try await runtime.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600)))
        try await runtime.activate(cloud.connectionID)
        #expect(try await runtime.stateStore.load() == nil)
        let localKey = ConnectionResourceID(connectionID: local.connectionIdentity.id, kind: "display", resourceID: "same")
        let cloudKey = ConnectionResourceID(connectionID: cloud.connectionID, kind: "display", resourceID: "same")
        #expect(localKey.encoded != cloudKey.encoded)
        #expect(ConnectionResourceID(encoded: "same") == nil)
    }

    @Test func readersWaitForSnapshotWriterBeforeEnumeratingReceipts() async throws {
        let (runtime, credentials, legacy, root, _) = fixture()
        let local = instance()
        await credentials.save(token: "local", for: local.id)
        await legacy.save(CompanionSnapshot(activeInstance: local, capabilities: nil, displays: [], dashboards: [], jobs: []))
        let snapshot = try #require(try await runtime.stateStore.load())
        let id = local.connectionIdentity.id
        let entered = root.appending(path: "writer-holds-lock")
        let release = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try SharedFileLock(url: runtime.registry.directory.appending(path: "\(id.fileComponent).snapshot.lock")).withLock {
                try Data().write(to: entered)
                _ = release.wait(timeout: .now() + 2)
            }
        }
        for _ in 0..<1000 {
            if FileManager.default.fileExists(atPath: entered.path) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(FileManager.default.fileExists(atPath: entered.path))
        defer { release.signal() }
        let completed = root.appending(path: "reader-finished")
        let reader = Task {
            let value = try await runtime.stateStore.load(for: id)
            try Data().write(to: completed)
            return value
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!FileManager.default.fileExists(atPath: completed.path))
        release.signal()
        try await holder.value
        #expect(try await reader.value?.connectionFence == snapshot.connectionFence)
    }

    @Test func oldLogoutCannotClearSelectionAfterSameConnectionRelogin() async throws {
        let http = DelayedRevocationTransport()
        let (runtime, credentials, legacy, _, _) = fixture(transport: http)
        let local = instance()
        await credentials.save(token: "old-local", for: local.id)
        await legacy.save(CompanionSnapshot(activeInstance: local, capabilities: nil, displays: [], dashboards: [], jobs: []))
        let old = try #require(try await runtime.stateStore.load())
        let logout = Task { try await runtime.signOut(#require(old.connectionFence)) }
        for _ in 0..<1000 {
            if await http.started { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await http.started)
        let fresh = try await runtime.installLocal(PairedSession(instance: local, token: "new-local", tokenID: "new",
                                                                scopes: [], createdAt: Date()))
        try await runtime.stateStore.save(old.binding(fresh))
        await http.unblock()
        try await logout.value
        #expect(try runtime.registry.selectedID() == fresh.connectionID)
        #expect(try await runtime.sessions.authorization(for: fresh).token == "new-local")
        #expect(try await runtime.stateStore.load()?.connectionFence == fresh)
        #expect(await http.revokedAuthorization == "Bearer old-local")
    }

    @Test func explicitLocalRetryPreservesIntentAndCannotTakeAnInFlightRequest() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let local = instance()
        let oldEpoch = UUID()
        let fresh = ConnectionFence(connectionID: local.connectionIdentity.id, epoch: UUID())
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let image = SharedImageRequest(instanceID: local.storageID, connectionEpoch: oldEpoch, fileName: "synthetic.jpg",
            contentType: "image/jpeg", fit: .fill, deviceIDs: ["same"], idempotencyKey: "keep-image-key", createdAt: created)
        let images = FileShareQueueStore(directoryURL: root)
        try await images.enqueue(imageData: Data([1]), request: image)
        let authorized = try await images.authorizeLocalRetry(image, instance: local, fence: fresh)
        #expect(authorized.id == image.id && authorized.idempotencyKey == image.idempotencyKey)
        #expect(authorized.createdAt == image.createdAt && authorized.deviceIDs == image.deviceIDs)
        #expect(authorized.connectionEpoch == fresh.epoch)
        await #expect(throws: ConnectionError.sessionChanged) { try await images.remove(image) }
        let submitting = authorized.updating(status: .submitting)
        try await images.update(submitting)
        await #expect(throws: ShareQueueStoreError.requestInProgress) {
            try await images.authorizeLocalRetry(submitting, instance: local, fence: fresh)
        }
        let links = FileLinkShareQueueStore(directoryURL: root)
        let link = SharedLinkRequest(instanceID: local.storageID, connectionEpoch: oldEpoch,
            url: URL(string: "https://example.invalid")!, kind: .webpage, fit: .fit,
            deviceIDs: ["same"], idempotencyKey: "keep-link-key", createdAt: created)
        try await links.enqueue(link)
        let authorizedLink = try await links.authorizeLocalRetry(link, instance: local, fence: fresh)
        #expect(authorizedLink.idempotencyKey == link.idempotencyKey && authorizedLink.createdAt == created)
        #expect(authorizedLink.connectionEpoch == fresh.epoch)
        await #expect(throws: ConnectionError.sessionChanged) { try await links.remove(link) }
        let inFlight = authorizedLink.updating(status: .submitting)
        try await links.update(inFlight)
        await #expect(throws: ShareQueueStoreError.requestInProgress) {
            try await links.authorizeLocalRetry(inFlight, instance: local, fence: fresh)
        }
        let other = instance(id: local.id, host: "different.local")
        await #expect(throws: ConnectionError.sessionChanged) {
            try await images.authorizeLocalRetry(image, instance: other, fence: fresh)
        }
    }
}

private actor DelayedRevocationTransport: TesseraeHTTPTransporting {
    var started = false
    var revokedAuthorization: String?
    private var continuation: CheckedContinuation<Void, Never>?
    func unblock() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        revokedAuthorization = request.value(forHTTPHeaderField: "Authorization")
        started = true
        await withCheckedContinuation { continuation = $0 }
        return TesseraeHTTPResponse(data: Data(), statusCode: 204)
    }
}
