import Foundation
import XCTest
@testable import TesseraeKit

final class PersonalDataClientTests: XCTestCase {
    func testReminderWithoutDueDateEncodesRequiredNullField() throws {
        let item = ReminderSnapshotItem(
            id: "undated-reminder",
            title: "Buy salt",
            dueDate: nil,
            priority: .none
        )

        let encoded = try TesseraeJSON.encoder().encode(item)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )

        XCTAssertTrue(object.keys.contains("due_date"))
        XCTAssertTrue(object["due_date"] is NSNull)
    }

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
            RemindersSnapshot.self,
            fixture: "personal-data-reminders.json"
        )
        let healthSnapshot = try decode(
            HealthSummarySnapshot.self,
            fixture: "personal-data-health-summary.json"
        )
        let status = try decode(
            PersonalDataStatusResponse.self,
            fixture: "personal-data-status.json"
        )

        XCTAssertTrue(capabilities.supports(personalDataSource: .reminders))
        XCTAssertEqual(
            capabilities.personalData?.sources,
            Set(["reminders", "reminders.fridge", "health.summary"])
        )
        XCTAssertTrue(capabilities.features.contains("personal_data_health"))
        XCTAssertTrue(capabilities.supports(personalDataSource: .healthSummary))
        XCTAssertTrue(capabilities.supportsHealthSummary)
        XCTAssertEqual(capabilities.limits.personalDataStaleAfterSeconds, 86_400)
        XCTAssertEqual(capabilities.limits.personalDataMaxTTLSeconds, 172_800)
        XCTAssertTrue(pairResponse.scopes.contains("personal_data:write"))
        XCTAssertEqual(snapshot.sourceID, .reminders)
        XCTAssertEqual(snapshot.data.lists.count, 2)
        XCTAssertEqual(snapshot.data.lists.first?.title, "Grocery List")
        XCTAssertEqual(snapshot.data.lists.first?.items.first?.priority, .high)
        XCTAssertEqual(healthSnapshot.sourceID, .healthSummary)
        XCTAssertEqual(healthSnapshot.data.timeZone, "Asia/Shanghai")
        XCTAssertEqual(healthSnapshot.data.activity?.days.count, 7)
        XCTAssertEqual(healthSnapshot.data.sleep?.nights.first?.wakeDate, "2026-08-14")
        XCTAssertEqual(healthSnapshot.data.workouts?.items.first?.activityType, .running)
        XCTAssertEqual(status.sources.first?.state, .fresh)
    }

    func testHealthNullableSectionsAndMetricsEncodeAsExplicitNull() throws {
        let snapshot = try decode(
            HealthSummarySnapshot.self,
            fixture: "personal-data-health-summary-partial.json"
        )

        let encoded = try TesseraeJSON.encoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        let data = try XCTUnwrap(object["data"] as? [String: Any])

        XCTAssertTrue(data.keys.contains("activity"))
        XCTAssertTrue(data["activity"] is NSNull)
        XCTAssertEqual(
            ((data["sleep"] as? [String: Any])?["nights"] as? [Any])?.count,
            0
        )
        XCTAssertTrue(data.keys.contains("workouts"))
        XCTAssertTrue(data["workouts"] is NSNull)

        let full = try decode(
            HealthSummarySnapshot.self,
            fixture: "personal-data-health-summary.json"
        )
        let fullEncoded = try TesseraeJSON.encoder().encode(full)
        let fullObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: fullEncoded) as? [String: Any]
        )
        let fullData = try XCTUnwrap(fullObject["data"] as? [String: Any])
        let workouts = try XCTUnwrap(fullData["workouts"] as? [String: Any])
        let items = try XCTUnwrap(workouts["items"] as? [[String: Any]])
        let workout = try XCTUnwrap(items.first)
        XCTAssertTrue(workout.keys.contains("cycling_distance_meters"))
        XCTAssertTrue(workout["cycling_distance_meters"] is NSNull)
    }

    func testLegacyFeatureDoesNotEnableNewRemindersBridge() {
        let capabilities = ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.235.0",
            api: CompanionAPI(version: 1),
            pairing: PairingCapabilities(supported: true, codeLength: 6, ttlSeconds: 600),
            features: ["personal_data_reminders"],
            limits: CompanionLimits(
                imageUploadBytes: 1,
                imageMaxEdge: 1,
                imageContentTypes: ["image/png"],
                jobRetentionSeconds: 60,
                idempotencyRetentionSeconds: 60
            ),
            webURL: "/"
        )

        XCTAssertFalse(capabilities.supports(personalDataSource: .reminders))
        XCTAssertFalse(capabilities.supports(personalDataSource: .remindersFridge))
    }

    func testHealthRequiresBothFeatureAndSourceAdvertisement() throws {
        let capabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities-personal-data.json"
        )
        let sourceOnly = ServerCapabilities(
            product: capabilities.product,
            serverVersion: capabilities.serverVersion,
            api: capabilities.api,
            pairing: capabilities.pairing,
            features: capabilities.features.subtracting(["personal_data_health"]),
            personalData: capabilities.personalData,
            limits: capabilities.limits,
            webURL: capabilities.webURL
        )
        let featureOnly = ServerCapabilities(
            product: capabilities.product,
            serverVersion: capabilities.serverVersion,
            api: capabilities.api,
            pairing: capabilities.pairing,
            features: capabilities.features,
            personalData: PersonalDataCapabilities(
                sources: ["reminders", "reminders.fridge"]
            ),
            limits: capabilities.limits,
            webURL: capabilities.webURL
        )

        XCTAssertFalse(sourceOnly.supportsHealthSummary)
        XCTAssertFalse(featureOnly.supportsHealthSummary)
    }

    func testPutMultiListSnapshotUsesGenericRemindersResource() async throws {
        let response = try fixtureResponse(
            "personal-data-reminders-put-response.json",
            statusCode: 200
        )
        let transport = RecordingPersonalDataTransport(responses: [response])
        let client = try await makeClient(transport: transport)
        let snapshot = try decode(
            RemindersSnapshot.self,
            fixture: "personal-data-reminders.json"
        )

        let accepted = try await client.putRemindersSnapshot(
            snapshot,
            instance: instance
        )

        XCTAssertEqual(accepted.sourceID, .reminders)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/personal-data/reminders")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_personal_data_test"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(
            try TesseraeJSON.decoder().decode(RemindersSnapshot.self, from: body),
            snapshot
        )
    }

    func testPutHealthSummaryUsesGenericHealthResource() async throws {
        let response = try fixtureResponse(
            "personal-data-health-summary-put-response.json",
            statusCode: 200
        )
        let transport = RecordingPersonalDataTransport(responses: [response])
        let client = try await makeClient(transport: transport)
        let snapshot = try decode(
            HealthSummarySnapshot.self,
            fixture: "personal-data-health-summary.json"
        )

        let accepted = try await client.putHealthSummarySnapshot(
            snapshot,
            instance: instance
        )

        XCTAssertEqual(accepted.sourceID, .healthSummary)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/personal-data/health.summary")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_personal_data_test"
        )
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let body = try XCTUnwrap(request.httpBody)
        XCTAssertEqual(
            try TesseraeJSON.decoder().decode(HealthSummarySnapshot.self, from: body),
            snapshot
        )
    }

    func testMockAcceptsHealthSummaryWithoutRendering() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let snapshot = try decode(
            HealthSummarySnapshot.self,
            fixture: "personal-data-health-summary.json"
        )

        let accepted = try await client.putHealthSummarySnapshot(
            snapshot,
            instance: instance
        )

        XCTAssertEqual(accepted.sourceID, .healthSummary)
        XCTAssertEqual(accepted.generatedAt, snapshot.generatedAt)
        XCTAssertEqual(accepted.expiresAt, snapshot.expiresAt)
    }

    func testStatusAndDeleteNeverReadSnapshotValues() async throws {
        let statusResponse = TesseraeHTTPResponse(
            data: try TesseraeJSON.encoder().encode(
                PersonalDataStatusResponse(
                    sources: [
                        PersonalDataSourceStatus(
                            sourceID: .reminders,
                            state: .fresh,
                            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                            staleAt: Date(timeIntervalSince1970: 1_700_086_400),
                            expiresAt: Date(timeIntervalSince1970: 1_700_172_800)
                        ),
                    ]
                )
            ),
            statusCode: 200
        )
        let deleteResponse = TesseraeHTTPResponse(data: Data(), statusCode: 204)
        let transport = RecordingPersonalDataTransport(
            responses: [statusResponse, deleteResponse]
        )
        let client = try await makeClient(transport: transport)

        let status = try await client.fetchPersonalDataStatus(instance: instance)
        try await client.deletePersonalData(
            sourceID: .reminders,
            instance: instance
        )

        XCTAssertEqual(status.sources.map(\.sourceID), [.reminders])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/app/v1/personal-data/status")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertEqual(
            requests[1].url?.path,
            "/api/app/v1/personal-data/reminders"
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
