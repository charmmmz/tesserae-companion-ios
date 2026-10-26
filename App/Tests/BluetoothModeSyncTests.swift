import Foundation
import Testing
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
struct BluetoothModeSyncTests {
    @Test(arguments: [false, true])
    func failedUploadRemainsPendingUntilSuccessfulRetry(includeStatus: Bool) async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil,
            batteryPercent: 65, firmwareVersion: "0.9.11")
        let transport = ModeReportTransport()
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "companion-secret", for: "home")
        let client = LiveTesseraeClient(credentials: credentials,
            identity: TesseraeClientIdentity(appVersion: "test", installationID: "test"), transport: transport)
        let model = AppModel(liveClient: client, demoClient: client, credentials: credentials,
            stateStore: InMemoryCompanionStateStore(), sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(), linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(), discovery: StaticDiscoveryService(results: []))
        model.activeInstance = TesseraeInstance(id: "home", name: "Home", baseURL: URL(string: "https://example.test")!,
            serverVersion: "test", timezone: "UTC", webURL: "/")
        model.connectionMode = .live
        let fixture = try await MockTesseraeClient(latency: .zero).probe(baseURL: model.activeInstance!.baseURL)
        model.capabilities = ServerCapabilities(product: fixture.product, serverVersion: fixture.serverVersion,
            api: fixture.api, pairing: fixture.pairing,
            features: fixture.features.union(includeStatus
                ? ["device_mode_observations", "device_status_observations"] : ["device_mode_observations"]),
            limits: fixture.limits, webURL: fixture.webURL)

        let pending = store.pendingModeReports(displayIDs: ["panel"], serverID: "home", includeStatus: includeStatus)
        #expect(pending.count == 1)
        await model.synchronizeBluetoothModes(pending, store: store)
        let restored = BluetoothDisplayStore(fileURL: file)
        #expect(restored.pendingModeReports(displayIDs: ["panel"], serverID: "home", includeStatus: includeStatus).count == 1)
        await model.synchronizeBluetoothModes(pending, store: restored)
        #expect(BluetoothDisplayStore(fileURL: file).pendingModeReports(displayIDs: ["panel"], serverID: "home", includeStatus: includeStatus).isEmpty)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests.last?.url?.path == "/api/app/v1/devices/panel/mode-observation")
        #expect(requests.last?.httpMethod == "PUT")
        #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer companion-secret")
        let body = try #require(requests.last?.httpBody)
        let observation = try TesseraeJSON.decoder().decode(DeviceModeObservation.self, from: body)
        #expect(observation == pending[0].observation)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(object.keys) == (includeStatus
            ? ["mode", "observed_at", "source", "battery", "firmware"] : ["mode", "observed_at", "source"]))
        #expect(observation.battery?.percent == (includeStatus ? 65 : nil))
        #expect(observation.firmware?.version == (includeStatus ? "0.9.11" : nil))

        // Old servers must not attempt unsupported uploads.
        model.capabilities = fixture
        await model.synchronizeBluetoothModes(pending, store: restored)
        #expect(await transport.requests.count == 2)
    }
}

private actor ModeReportTransport: TesseraeHTTPTransporting {
    private(set) var requests: [URLRequest] = []

    func send(_ request: URLRequest) throws -> TesseraeHTTPResponse {
        requests.append(request)
        if requests.count == 1 { throw URLError(.notConnectedToInternet) }
        return TesseraeHTTPResponse(data: Data(), statusCode: 204)
    }
}
