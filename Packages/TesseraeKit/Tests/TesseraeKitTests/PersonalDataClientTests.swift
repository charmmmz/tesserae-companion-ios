import Foundation
import XCTest
@testable import TesseraeKit

final class PersonalDataClientTests: XCTestCase {
    func testContractFixturesDecodeIntoPersonalDataModels() throws {
        let capabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities-personal-data.json"
        )
        let pairResponse = try decode(
            PairingResponse.self,
            fixture: "pair-response-personal-data.json"
        )
        let snapshot = try decode(
            RemindersFridgeSnapshot.self,
            fixture: "personal-data-reminders-fridge.json"
        )
        let status = try decode(
            PersonalDataStatusResponse.self,
            fixture: "personal-data-status.json"
        )

        XCTAssertTrue(capabilities.supports(personalDataSource: .remindersFridge))
        XCTAssertEqual(capabilities.limits.personalDataStaleAfterSeconds, 86_400)
        XCTAssertEqual(capabilities.limits.personalDataMaxTTLSeconds, 172_800)
        XCTAssertTrue(pairResponse.scopes.contains("personal_data:write"))
        XCTAssertEqual(snapshot.sourceID, .remindersFridge)
        XCTAssertEqual(snapshot.data.items.count, 3)
        XCTAssertEqual(snapshot.data.items.first?.priority, .high)
        XCTAssertEqual(status.sources.first?.state, .fresh)
    }

    func testPutSnapshotUsesScopedResourceAndNoIdempotencyHeader() async throws {
        let response = try fixtureResponse(
            "personal-data-put-response.json",
            statusCode: 200
        )
        let transport = RecordingPersonalDataTransport(responses: [response])
        let client = try await makeClient(transport: transport)
        let snapshot = try decode(
            RemindersFridgeSnapshot.self,
            fixture: "personal-data-reminders-fridge.json"
        )

        let accepted = try await client.putRemindersFridgeSnapshot(
            snapshot,
            instance: instance
        )

        XCTAssertEqual(accepted.state, .fresh)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/personal-data/reminders.fridge"
        )
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_personal_data_test"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(
            try TesseraeJSON.decoder().decode(
                RemindersFridgeSnapshot.self,
                from: body
            ),
            snapshot
        )
    }

    func testStatusAndDeleteNeverReadSnapshotValues() async throws {
        let statusResponse = try fixtureResponse(
            "personal-data-status.json",
            statusCode: 200
        )
        let deleteResponse = TesseraeHTTPResponse(data: Data(), statusCode: 204)
        let transport = RecordingPersonalDataTransport(
            responses: [statusResponse, deleteResponse]
        )
        let client = try await makeClient(transport: transport)

        let status = try await client.fetchPersonalDataStatus(instance: instance)
        try await client.deletePersonalData(
            sourceID: .remindersFridge,
            instance: instance
        )

        XCTAssertEqual(status.sources.map(\.sourceID), [.remindersFridge])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/app/v1/personal-data/status")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(
            requests[1].url?.path,
            "/api/app/v1/personal-data/reminders.fridge"
        )
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
        XCTAssertNil(requests[1].httpBody)
    }

    private func makeClient(
        transport: RecordingPersonalDataTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(
            token: "tc_personal_data_test",
            for: instance.id
        )
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.4.0",
                installationID: "personal-data-test-installation"
            ),
            transport: transport
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        fixture: String
    ) throws -> Value {
        try TesseraeJSON.decoder().decode(
            type,
            from: Data(contentsOf: fixturesURL.appending(path: fixture))
        )
    }

    private func fixtureResponse(
        _ fixture: String,
        statusCode: Int
    ) throws -> TesseraeHTTPResponse {
        TesseraeHTTPResponse(
            data: try Data(contentsOf: fixturesURL.appending(path: fixture)),
            statusCode: statusCode
        )
    }

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures")
            .standardizedFileURL
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.226.0+personal-data-fixture",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }
}

private actor RecordingPersonalDataTransport: TesseraeHTTPTransporting {
    private var responses: [TesseraeHTTPResponse]
    private var requests: [URLRequest] = []

    init(responses: [TesseraeHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> TesseraeHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            throw TesseraeClientError.unavailable
        }
        return responses.removeFirst()
    }

    func lastRequest() -> URLRequest? {
        requests.last
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }
}
