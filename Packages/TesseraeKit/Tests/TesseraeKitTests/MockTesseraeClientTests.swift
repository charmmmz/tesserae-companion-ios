import XCTest
@testable import TesseraeKit

final class MockTesseraeClientTests: XCTestCase {
    private let baseURL = URL(string: "http://tesserae.local:8765")!
    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures")
            .standardizedFileURL
    }

    func testProbeAdvertisesFoundationFeatures() async throws {
        let client = MockTesseraeClient(latency: .zero)

        let capabilities = try await client.probe(baseURL: baseURL)

        XCTAssertEqual(capabilities.product, "tesserae")
        XCTAssertTrue(capabilities.features.contains("dashboard_push"))
        XCTAssertTrue(capabilities.features.contains("image_push"))
        XCTAssertEqual(capabilities.limits.imageMaxEdge, 8_192)
        XCTAssertTrue(capabilities.limits.imageContentTypes.contains("image/heic"))
    }

    func testPairRejectsNonSixDigitCode() async {
        let client = MockTesseraeClient(latency: .zero)

        do {
            _ = try await client.pair(baseURL: baseURL, code: "abc", clientName: "Test iPhone")
            XCTFail("Expected invalidPairingCode")
        } catch {
            XCTAssertEqual(error as? TesseraeClientError, .invalidPairingCode)
        }
    }

    func testDashboardPushRequiresTargets() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: baseURL,
            code: "123456",
            clientName: "Test iPhone"
        )

        do {
            _ = try await client.pushDashboard(
                id: "morning",
                deviceIDs: [],
                overrideQuietHours: false,
                idempotencyKey: UUID().uuidString,
                instance: session.instance
            )
            XCTFail("Expected noTargets")
        } catch {
            XCTAssertEqual(error as? TesseraeClientError, .noTargets)
        }
    }

    func testAcceptedDashboardJobBecomesPublishedOnPoll() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: baseURL,
            code: "123456",
            clientName: "Test iPhone"
        )
        let idempotencyKey = UUID().uuidString

        let accepted = try await client.pushDashboard(
            id: "morning",
            deviceIDs: ["e1004-desk"],
            overrideQuietHours: false,
            idempotencyKey: idempotencyKey,
            instance: session.instance
        )
        let completed = try await client.fetchJob(id: accepted.id, instance: session.instance)

        XCTAssertEqual(accepted.status, .accepted)
        XCTAssertEqual(completed.status, .succeeded)
        XCTAssertEqual(completed.result?.status, .published)
    }

    func testIdempotencyKeyReturnsSameAcceptedJob() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: baseURL,
            code: "123456",
            clientName: "Test iPhone"
        )
        let idempotencyKey = UUID().uuidString

        let first = try await client.pushDashboard(
            id: "morning",
            deviceIDs: ["e1004-desk"],
            overrideQuietHours: false,
            idempotencyKey: idempotencyKey,
            instance: session.instance
        )
        let retry = try await client.pushDashboard(
            id: "morning",
            deviceIDs: ["e1004-desk"],
            overrideQuietHours: false,
            idempotencyKey: idempotencyKey,
            instance: session.instance
        )

        XCTAssertEqual(first.id, retry.id)
    }

    func testContractFixturesDecodeIntoSwiftModels() throws {
        let decoder = TesseraeJSON.decoder()

        let capabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities.json",
            decoder: decoder
        )
        let pairRequest = try decode(
            PairingRequest.self,
            fixture: "pair-request.json",
            decoder: decoder
        )
        let pairResponse = try decode(
            PairingResponse.self,
            fixture: "pair-response.json",
            decoder: decoder
        )
        let devices = try decode(
            DevicesResponse.self,
            fixture: "devices-response.json",
            decoder: decoder
        )
        let dashboards = try decode(
            DashboardsResponse.self,
            fixture: "dashboards-response.json",
            decoder: decoder
        )
        let dashboardPush = try decode(
            DashboardPushRequest.self,
            fixture: "dashboard-push-request.json",
            decoder: decoder
        )
        let imagePush = try decode(
            ImagePushRequest.self,
            fixture: "image-push-request.json",
            decoder: decoder
        )
        let accepted = try decode(
            JobResponse.self,
            fixture: "job-accepted.json",
            decoder: decoder
        )
        let published = try decode(
            JobResponse.self,
            fixture: "job-published.json",
            decoder: decoder
        )
        let quiet = try decode(
            JobResponse.self,
            fixture: "job-quiet.json",
            decoder: decoder
        )
        let failed = try decode(
            JobResponse.self,
            fixture: "job-failed.json",
            decoder: decoder
        )
        let error = try decode(
            APIErrorResponse.self,
            fixture: "error-response.json",
            decoder: decoder
        )

        XCTAssertEqual(capabilities.api.version, 1)
        XCTAssertEqual(pairRequest.client.installationID, "A1B2C3D4-E5F6-47A8-9012-3456789ABCDE")
        XCTAssertEqual(pairResponse.tokenID, "ct_01JABCDEF")
        XCTAssertEqual(devices.devices.first?.rssiDBM, -54)
        XCTAssertEqual(dashboards.dashboards.first?.deviceIDs, ["picpak-kitchen"])
        XCTAssertEqual(dashboardPush.deviceIDs, ["picpak-kitchen"])
        XCTAssertEqual(imagePush.fit, .fill)
        XCTAssertEqual(accepted.job.status, .accepted)
        XCTAssertEqual(published.job.result?.status, .published)
        XCTAssertEqual(quiet.job.result?.status, .quiet)
        XCTAssertEqual(failed.job.error?.code, "render_failed")
        XCTAssertEqual(error.error.requestID, "req_01JABCDEF")
    }

    func testRequestModelsEncodeSnakeCaseKeys() throws {
        let encoder = TesseraeJSON.encoder()
        let request = DashboardPushRequest(
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: true
        )

        let data = try encoder.encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(json["device_ids"] as? [String], ["picpak-kitchen"])
        XCTAssertEqual(json["override_quiet_hours"] as? Bool, true)
        XCTAssertNil(json["deviceIds"])
    }

    private func decode<T: Decodable>(
        _ type: T.Type,
        fixture name: String,
        decoder: JSONDecoder
    ) throws -> T {
        let data = try Data(contentsOf: fixturesURL.appending(path: name))
        return try decoder.decode(type, from: data)
    }
}
