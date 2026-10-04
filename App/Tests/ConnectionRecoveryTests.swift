import Foundation
import TesseraeKit
import XCTest
import Testing

@testable import Tesserae_Companion

@MainActor
final class ConnectionRecoveryTests: XCTestCase {
    func testRestoreReleasesCachedUIBeforeProbeAndTimesOutWithoutLosingPairing() async throws {
        let fixture = try await makeFixture(timeout: .milliseconds(40), delay: .seconds(10))
        let restore = Task { await fixture.model.restoreConnectionIfNeeded() }
        await waitForRequest(fixture.transport)
        XCTAssertFalse(fixture.model.isRestoringConnection)
        XCTAssertEqual(fixture.model.activeInstance?.id, "saved")
        XCTAssertEqual(fixture.model.displays.count, fixture.snapshot.displays.count)
        await restore.value
        XCTAssertEqual(fixture.model.connectionHealth, .offline)
        XCTAssertNotNil(fixture.model.connectionNotice)
        XCTAssertNil(fixture.model.lastError)
        let token = await fixture.credentials.token(for: "saved")
        let snapshot = await fixture.store.load()
        XCTAssertEqual(token, "saved-token")
        XCTAssertEqual(snapshot?.activeInstance.id, "saved")
    }

    func testOldRestoreFailureCannotReplaceNewConnection() async throws {
        let fixture = try await makeFixture(delay: .milliseconds(300))
        let restore = Task { await fixture.model.restoreConnectionIfNeeded() }
        await waitForRequest(fixture.transport)
        await fixture.model.connectDemo()
        let newID = fixture.model.activeInstance?.id
        await restore.value
        XCTAssertEqual(fixture.model.connectionMode, .demo)
        XCTAssertEqual(fixture.model.activeInstance?.id, newID)
        XCTAssertEqual(fixture.model.connectionHealth, .connected)
        XCTAssertNil(fixture.model.connectionNotice)
    }

    func testOldRefreshUnauthorizedCannotRemoveNewConnection() async throws {
        let fixture = try await makeFixture(delay: .milliseconds(300), unauthorized: true)
        fixture.model.activeInstance = fixture.snapshot.activeInstance
        fixture.model.connectionMode = .live
        fixture.model.connectionHealth = .connected
        let refresh = Task { await fixture.model.refresh(probeCapabilities: false) }
        await waitForRequest(fixture.transport)
        await fixture.model.connectDemo()
        await refresh.value
        XCTAssertEqual(fixture.model.connectionMode, .demo)
        XCTAssertEqual(fixture.model.connectionHealth, .connected)
        XCTAssertFalse(fixture.model.displays.isEmpty)
        XCTAssertNil(fixture.model.connectionNotice)
    }

    func testFailedNewServerKeepsPreviousPairingAndDiscoveryWorksWhilePaired() async throws {
        let fixture = try await makeFixture(delay: .zero)
        fixture.model.activeInstance = fixture.snapshot.activeInstance
        fixture.model.connectionMode = .live
        fixture.model.connectionHealth = .offline
        let connected = await fixture.model.connectLive(
            baseURL: URL(string: "http://other.local")!, code: "123456", clientName: "Test"
        )
        XCTAssertFalse(connected)
        XCTAssertEqual(fixture.model.activeInstance?.id, "saved")
        let token = await fixture.credentials.token(for: "saved")
        XCTAssertEqual(token, "saved-token")
        await fixture.model.discoverNearby()
        XCTAssertEqual(fixture.model.discoveredInstances.map(\.id), ["other"])
        XCTAssertFalse(fixture.model.isDiscovering)
    }

    func testCancelledConnectionClearsProgressWithoutPresentingError() async throws {
        let fixture = try await makeFixture(delay: .seconds(10))
        let connection = Task {
            await fixture.model.connectLive(
                baseURL: URL(string: "http://other.local")!, code: "123456", clientName: "Test"
            )
        }
        await waitForRequest(fixture.transport)
        connection.cancel()
        let connected = await connection.value
        XCTAssertFalse(connected)
        XCTAssertFalse(fixture.model.activeOperationIDs.contains("pair"))
        XCTAssertNil(fixture.model.lastError)
    }

    func testLocalActivityRefreshCannotMarkAnOfflineServerConnected() async throws {
        let fixture = try await makeFixture(delay: .zero)
        fixture.model.activeInstance = fixture.snapshot.activeInstance
        fixture.model.connectionMode = .live
        fixture.model.connectionHealth = .offline
        fixture.model.connectionNotice = "Server unavailable"
        await fixture.model.refreshActivity()
        XCTAssertEqual(fixture.model.connectionHealth, .offline)
        XCTAssertEqual(fixture.model.connectionNotice, "Server unavailable")
        let requested = await fixture.transport.started
        XCTAssertFalse(requested)
    }

    private func waitForRequest(_ transport: DelayedConnectionTransport) async {
        for _ in 0..<200 {
            if await transport.started { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Connection request never started")
    }

    private func makeFixture(
        timeout: Duration = .seconds(2), delay: Duration, unauthorized: Bool = false
    ) async throws -> (
        model: AppModel, transport: DelayedConnectionTransport,
        credentials: InMemoryCredentialStore, store: InMemoryCompanionStateStore,
        snapshot: CompanionSnapshot
    ) {
        let demo = MockTesseraeClient(latency: .zero)
        let instance = TesseraeInstance(
            id: "saved", name: "Saved Tesserae", baseURL: URL(string: "http://saved.local")!,
            serverVersion: "0.311.0", timezone: "Asia/Shanghai", webURL: "/"
        )
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "saved-token", for: instance.id)
        let snapshot = CompanionSnapshot(
            activeInstance: instance, capabilities: nil,
            displays: try await demo.fetchDisplays(instance: instance),
            dashboards: [], jobs: [], updatedAt: Date()
        )
        let store = InMemoryCompanionStateStore(snapshot: snapshot)
        let transport = DelayedConnectionTransport(delay: delay, unauthorized: unauthorized)
        let client = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(appVersion: "test", installationID: "test"),
            transport: transport
        )
        let model = AppModel(
            liveClient: client, demoClient: demo, credentials: credentials, stateStore: store,
            sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(), linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: [
                DiscoveredInstance(
                    id: "other", name: "Other", baseURL: URL(string: "http://other.local")!
                )
            ]), connectionTimeout: timeout
        )
        return (model, transport, credentials, store, snapshot)
    }
}

private actor DelayedConnectionTransport: TesseraeHTTPTransporting {
    let delay: Duration
    let unauthorized: Bool
    private(set) var started = false

    init(delay: Duration, unauthorized: Bool) {
        self.delay = delay
        self.unauthorized = unauthorized
    }

    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        started = true
        try await Task.sleep(for: delay)
        if unauthorized { return TesseraeHTTPResponse(data: Data(), statusCode: 401) }
        throw URLError(.cannotConnectToHost)
    }
}

// Continuations deliberately ignore cancellation so the tests exercise late callbacks.
actor SessionTestGate {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor SessionTestTransport: TesseraeHTTPTransporting {
    let gate = SessionTestGate()
    let response: TesseraeHTTPResponse
    private(set) var requestCount = 0

    init(response: TesseraeHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        requestCount += 1
        if requestCount == 1 { await gate.pause() }
        return response
    }
}

@Suite("Server session isolation", .timeLimit(.minutes(1)))
@MainActor
struct ServerSessionIsolationTests {
    @Test("A late Gallery 401 cannot revoke the new pairing", arguments: ["folders", "folder", "album", "permission"], [false, true])
    func oldGalleryUnauthorized(resource: String, rePairSameID: Bool) async throws {
        let fixture = try await makeFixture(response: .init(data: Data(), statusCode: 401))
        let model = fixture.model
        if rePairSameID {
            let old = model.activeInstance!
            model.activeInstance = TesseraeInstance(id: "demo-home", name: old.name, baseURL: old.baseURL,
                serverVersion: old.serverVersion, timezone: old.timezone, webURL: old.webURL)
            await fixture.credentials.save(token: "old-token", for: "demo-home")
        }
        let request = Task {
            switch resource {
            case "folders": await model.refreshGallery()
            case "folder": await model.refreshGalleryFolder(id: "old-folder")
            case "album": await model.refreshOfflineAlbum(folderID: "old-folder")
            default: await model.refreshGalleryWritePermission(showErrors: true)
            }
        }
        await fixture.transport.gate.waitUntilStarted()
        await model.connectDemo()
        let newID = try #require(model.activeInstance?.id)
        await fixture.credentials.save(token: "new-token", for: newID)
        let newSnapshot = CompanionSnapshot(activeInstance: model.activeInstance!, capabilities: model.capabilities,
                                            displays: model.displays, dashboards: model.dashboards, jobs: [])
        await fixture.store.save(newSnapshot)
        await fixture.transport.gate.release()
        await request.value
        #expect(model.activeInstance?.id == newID)
        #expect(model.connectionHealth == .connected)
        #expect(await fixture.credentials.token(for: newID) == "new-token")
        #expect(await fixture.store.load()?.activeInstance.id == newID)
        #expect(model.lastError == nil)
        #expect(!model.isRefreshingGallery)
        #expect(model.loadingGalleryFolderIDs.isEmpty)
        #expect(model.loadingOfflineAlbumFolderIDs.isEmpty)
    }

    @Test("A late Lineup write cannot change the new session", arguments: ["enable", "create", "update", "control"])
    func oldLineupWrite(operation: String) async throws {
        let demo = MockTesseraeClient(latency: .zero)
        let instance = oldInstance
        var lineup = try #require(try await demo.fetchLineups(instance: instance).first)
        // Keep the ID shared with the new demo server so an accidental overwrite is visible.
        let patch = LineupPatchRequest(name: "Old server response")
        let versioned = try await demo.fetchVersionedLineup(id: lineup.id, instance: instance)
        lineup = try await demo.updateLineup(id: lineup.id, eTag: versioned.eTag, patch: patch, instance: instance).lineup
        let job = PushJob(id: "old-session-job", kind: .lineupAction, status: .succeeded,
                          label: "Old server job", targetDeviceIDs: [], createdAt: .now, updatedAt: .now)
        struct LineupBody: Encodable { let lineup: Lineup }
        struct JobBody: Encodable { let job: PushJob }
        let data = try operation == "control"
            ? TesseraeJSON.encoder().encode(JobBody(job: job))
            : TesseraeJSON.encoder().encode(LineupBody(lineup: lineup))
        let fixture = try await makeFixture(response: .init(data: data,
            statusCode: operation == "create" ? 201 : (operation == "control" ? 202 : 200),
            headers: ["ETag": "\"old-etag\""]))
        let model = fixture.model
        let original = lineup
        let request = Task {
            switch operation {
            case "enable": _ = await model.setLineupEnabled(original, enabled: false)
            case "create": _ = await model.createLineup(.init(intent: .manual, name: "Old server response", pageIDs: ["pantry"], deviceIDs: []))
            case "update": _ = await model.updateLineup(id: original.id, eTag: "\"old\"", patch: patch)
            default: _ = await model.controlLineup(original, action: .next, deviceIDs: ["picpak-kitchen"])
            }
        }
        await fixture.transport.gate.waitUntilStarted()
        await model.connectDemo()
        let expectedLineups = model.lineups
        model.connectionMode = .live
        await fixture.store.save(CompanionSnapshot(activeInstance: model.activeInstance!, capabilities: model.capabilities,
            displays: model.displays, dashboards: model.dashboards, lineups: expectedLineups, jobs: []))
        await fixture.transport.gate.release()
        await request.value
        #expect(model.lineups == expectedLineups)
        #expect(await fixture.store.load()?.lineups == expectedLineups)
        #expect(model.jobs.allSatisfy { $0.id != job.id })
        #expect(model.lastError == nil)
        #expect(model.lineupAuthoringPermission == .granted)
        #expect(model.activeOperationIDs.isEmpty)
        #expect(await fixture.transport.requestCount == 1)
    }

    @Test("Late photo and link errors cannot revoke a new server", arguments: ["photo", "webpage"])
    func oldSendUnauthorized(kind: String) async throws {
        let fixture = try await makeFixture(response: .init(data: Data(), statusCode: 401))
        let model = fixture.model
        let send = Task {
            if kind == "photo" {
                return await model.sendImage(data: Data("image".utf8), fit: .fill,
                    deviceIDs: ["picpak-kitchen"], contentType: "image/jpeg")
            }
            return await model.sendLink(url: URL(string: "https://example.com")!, kind: .webpage,
                                        fit: .fill, deviceIDs: ["picpak-kitchen"])
        }
        await fixture.transport.gate.waitUntilStarted()
        await model.connectDemo()
        let id = try #require(model.activeInstance?.id)
        await fixture.credentials.save(token: "new-token", for: id)
        await fixture.transport.gate.release()
        #expect(await send.value == false)
        #expect(model.activeInstance?.id == id)
        #expect(await fixture.credentials.token(for: id) == "new-token")
        #expect(model.lastError == nil)
    }

    @Test("Disconnect makes personal data unavailable before revocation completes")
    func disconnectInvalidatesSessionImmediately() async throws {
        let fixture = try await makeFixture(response: .init(data: Data(), statusCode: 204))
        let oldSession = try #require(fixture.model.connectionSession)
        let disconnect = Task { await fixture.model.disconnect() }
        await fixture.transport.gate.waitUntilStarted()
        #expect(fixture.model.connectionSession == nil)
        await #expect(throws: CancellationError.self) {
            try await fixture.model.remindersPersonalDataStatus(session: oldSession)
        }
        await fixture.model.connectDemo()
        let newID = fixture.model.activeInstance?.id
        await fixture.transport.gate.release()
        await disconnect.value
        #expect(fixture.model.activeInstance?.id == newID)
        #expect(fixture.model.connectionSession != nil)
    }

    @Test("Only a new connection resets navigation identity")
    func navigationSessionIdentity() async throws {
        let fixture = try await makeFixture(response: .init(data: Data(), statusCode: 401))
        await fixture.model.connectDemo()
        let revision = fixture.model.connectionRevision
        await fixture.model.refresh()
        #expect(fixture.model.connectionRevision == revision)
        await fixture.model.connectDemo()
        #expect(fixture.model.connectionRevision != revision)
    }

    @Test("An obsolete personal data session cannot start a request")
    func rejectsObsoletePersonalDataSession() async throws {
        let fixture = try await makeFixture(response: .init(data: Data(), statusCode: 401))
        let session = try #require(fixture.model.connectionSession)
        await fixture.model.connectDemo()
        let snapshot = ReminderSnapshotFactory.makeSnapshot(from: [], serverMaximumTTLSeconds: nil)
        await #expect(throws: CancellationError.self) {
            try await fixture.model.putRemindersSnapshot(snapshot, session: session)
        }
        #expect(await fixture.transport.requestCount == 0)
    }

    private var oldInstance: TesseraeInstance {
        TesseraeInstance(id: "old-server", name: "Old server", baseURL: URL(string: "http://old.test")!,
                         serverVersion: "0.441.5", timezone: "UTC", webURL: "/")
    }

    private func makeFixture(response: TesseraeHTTPResponse) async throws -> (
        model: AppModel, transport: SessionTestTransport, credentials: InMemoryCredentialStore,
        store: InMemoryCompanionStateStore
    ) {
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "old-token", for: oldInstance.id)
        let store = InMemoryCompanionStateStore()
        let transport = SessionTestTransport(response: response)
        let live = LiveTesseraeClient(credentials: credentials,
            identity: .init(appVersion: "test", installationID: "test"), transport: transport)
        let demo = MockTesseraeClient(latency: .zero)
        let model = AppModel(liveClient: live, demoClient: demo, credentials: credentials, stateStore: store,
            sendPreferences: InMemoryCompanionSendPreferencesStore(), shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(), activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: []))
        model.activeInstance = oldInstance
        model.connectionMode = .live
        model.connectionHealth = .connected
        model.capabilities = try await demo.probe(baseURL: oldInstance.baseURL)
        return (model, transport, credentials, store)
    }
}
