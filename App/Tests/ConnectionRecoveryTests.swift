import Foundation
import TesseraeKit
import XCTest

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
