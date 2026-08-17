import Foundation
import XCTest
@testable import TesseraeKit

final class DeviceTimelineClientTests: XCTestCase {
    func testUpcomingFixtureDecodesProjectedEvents() throws {
        let data = try Data(contentsOf: fixtureURL("device-upcoming-response.json"))
        let response = try TesseraeJSON.decoder().decode(
            DeviceUpcomingResponse.self,
            from: data
        )

        XCTAssertEqual(response.deviceID, "picpak-kitchen")
        XCTAssertEqual(response.timezone, "Asia/Shanghai")
        XCTAssertNotNil(response.currentFrameAt)
        XCTAssertEqual(response.events.map(\.cause), [.cycle, .interval])
        XCTAssertEqual(response.events.map(\.effect), [.changeScreen, .refreshScreen])
        XCTAssertEqual(response.events.first?.dashboardName, "Morning Overview")
        XCTAssertNil(response.events.last?.dashboardID)
    }

    func testLiveClientUsesAuthenticatedUpcomingQuery() async throws {
        let data = try Data(contentsOf: fixtureURL("device-upcoming-response.json"))
        let transport = RecordingDeviceTimelineTransport(
            response: TesseraeHTTPResponse(data: data, statusCode: 200)
        )
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "timeline-secret", for: "home")
        let client = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.6.3",
                installationID: "timeline-test"
            ),
            transport: transport
        )

        let response = try await client.fetchDeviceUpcoming(
            id: "picpak-kitchen",
            hours: 24,
            limit: 6,
            instance: instance
        )

        XCTAssertEqual(response.events.count, 2)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/devices/picpak-kitchen/upcoming"
        )
        let components = try XCTUnwrap(
            request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            })["hours"],
            "24"
        )
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value)
            })["limit"],
            "6"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer timeline-secret"
        )
    }

    func testCapabilityRequiresAdvertisedBounds() {
        let limits = CompanionLimits(
            imageUploadBytes: 1,
            imageMaxEdge: 1,
            imageContentTypes: ["image/png"],
            deviceTimelineMaxHours: 168,
            deviceTimelineMaxEvents: 20,
            jobRetentionSeconds: 60,
            idempotencyRetentionSeconds: 60
        )
        let capability = ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.311.0",
            api: CompanionAPI(version: 1),
            pairing: PairingCapabilities(supported: true, codeLength: 6, ttlSeconds: 600),
            features: ["device_timeline"],
            limits: limits,
            webURL: "/"
        )

        XCTAssertTrue(capability.supportsDeviceTimeline)
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.311.0",
            timezone: "Asia/Shanghai",
            webURL: "/"
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures")
            .appending(path: name)
            .standardizedFileURL
    }
}

private actor RecordingDeviceTimelineTransport: TesseraeHTTPTransporting {
    private let response: TesseraeHTTPResponse
    private var request: URLRequest?

    init(response: TesseraeHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) -> TesseraeHTTPResponse {
        self.request = request
        return response
    }

    func lastRequest() -> URLRequest? {
        request
    }
}
