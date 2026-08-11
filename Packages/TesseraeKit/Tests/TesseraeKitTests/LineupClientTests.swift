import Foundation
import XCTest
@testable import TesseraeKit

final class LineupClientTests: XCTestCase {
    func testAdvancedLineupFixtureDecodesWithoutDroppingServerFields() throws {
        let data = try Data(contentsOf: fixtureURL("lineups-response.json"))
        let response = try TesseraeJSON.decoder().decode(LineupsResponse.self, from: data)
        let advanced = try XCTUnwrap(response.lineups.last)

        XCTAssertEqual(advanced.intent, .cycle)
        XCTAssertFalse(advanced.nativeEditable)
        XCTAssertEqual(advanced.mode, .priority)
        XCTAssertEqual(advanced.smartSync, true)
        XCTAssertEqual(advanced.current.count, 2)
        XCTAssertEqual(
            advanced.current.last?.pageID,
            "morning"
        )
        let conditions = try XCTUnwrap(advanced.dashboards.first?.conditions)
        XCTAssertEqual(conditions.count, 3)
        XCTAssertEqual(
            conditions.first?.value,
            .string("on")
        )
    }

    func testDeployedUpstreamProjectionDecodesBeforeAdditiveFieldsShip() throws {
        let data = try Data(
            contentsOf: fixtureURL("lineups-upstream-v0.289.2-response.json")
        )
        let response = try TesseraeJSON.decoder().decode(LineupsResponse.self, from: data)
        let lineup = try XCTUnwrap(response.lineups.first)

        XCTAssertEqual(lineup.trigger, .cycle)
        XCTAssertEqual(lineup.current.first?.pageID, "pantry")
        XCTAssertNil(lineup.homeTimeoutMinutes)
        XCTAssertNil(lineup.dashboards.first?.conditions)
    }

    func testDisplayActionUsesJobEndpointAndIdempotency() async throws {
        let responseData = try Data(contentsOf: fixtureURL("job-lineup-action.json"))
        let transport = RecordingLineupTransport(
            response: TesseraeHTTPResponse(data: responseData, statusCode: 202)
        )
        let client = try await makeClient(transport: transport)

        let job = try await client.controlLineup(
            id: "kitchen-deck",
            action: .play,
            pageID: "pantry",
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: true,
            idempotencyKey: "lineup-action-test-0001",
            instance: instance
        )

        XCTAssertEqual(job.kind, .lineupAction)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/lineups/kitchen-deck/actions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "lineup-action-test-0001"
        )
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)
        ) as? [String: Any]
        XCTAssertEqual(body?["action"] as? String, "play")
        XCTAssertEqual(body?["page_id"] as? String, "pantry")
        XCTAssertEqual(body?["device_ids"] as? [String], ["picpak-kitchen"])
        XCTAssertEqual(body?["override_quiet_hours"] as? Bool, true)
    }

    func testEnabledUpdateUsesSynchronousActionWithoutIdempotency() async throws {
        let fixtureData = try Data(contentsOf: fixtureURL("lineup-response.json"))
        var fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fixtureData) as? [String: Any]
        )
        var lineup = try XCTUnwrap(fixture["lineup"] as? [String: Any])
        lineup["enabled"] = false
        fixture["lineup"] = lineup
        let responseData = try JSONSerialization.data(withJSONObject: fixture)
        let transport = RecordingLineupTransport(
            response: TesseraeHTTPResponse(data: responseData, statusCode: 200)
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.setLineupEnabled(
            id: "kitchen-deck",
            enabled: false,
            instance: instance
        )

        XCTAssertFalse(result.enabled)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/lineups/kitchen-deck/actions")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(request.httpBody)
        ) as? [String: Any]
        XCTAssertEqual(body?["action"] as? String, "disable")
    }

    func testMissingLineupScopeIsForbiddenRatherThanUnauthorized() async throws {
        let body = """
        {
          "error": {
            "code": "forbidden",
            "message": "Grant this permission in Tesserae Settings.",
            "request_id": "req_forbidden_01"
          }
        }
        """
        let transport = RecordingLineupTransport(
            response: TesseraeHTTPResponse(
                data: Data(body.utf8),
                statusCode: 403
            )
        )
        let client = try await makeClient(transport: transport)

        do {
            _ = try await client.fetchLineups(instance: instance)
            XCTFail("Expected forbidden")
        } catch {
            XCTAssertEqual(
                error as? TesseraeClientError,
                .forbidden(
                    message: "Grant this permission in Tesserae Settings.",
                    requestID: "req_forbidden_01"
                )
            )
        }
    }

    private func makeClient(
        transport: RecordingLineupTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "tc_lineup_test", for: instance.id)
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.5.2",
                installationID: "lineup-test-installation"
            ),
            transport: transport
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures/\(name)")
            .standardizedFileURL
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.289.2",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }
}

private actor RecordingLineupTransport: TesseraeHTTPTransporting {
    private let response: TesseraeHTTPResponse
    private var requests: [URLRequest] = []

    init(response: TesseraeHTTPResponse) {
        self.response = response
    }

    func send(_ request: URLRequest) -> TesseraeHTTPResponse {
        requests.append(request)
        return response
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }
}
