import Foundation
import XCTest
@testable import TesseraeKit

final class LinkPushClientTests: XCTestCase {
    func testImageURLPushUsesContractEndpointAndJSONBody() async throws {
        let transport = RecordingLinkPushTransport(
            response: try acceptedJobResponse(kind: .imageURLPush)
        )
        let client = try await makeClient(transport: transport)

        let job = try await client.sendImageURL(
            url: try XCTUnwrap(URL(string: "https://images.example.com/photo.jpg")),
            fit: .fill,
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: true,
            idempotencyKey: "image-url-idempotency-0001",
            instance: instance
        )

        XCTAssertEqual(job.kind, .imageURLPush)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/image-urls")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_link_push_test"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "image-url-idempotency-0001"
        )
        let body = try decodeJSONBody(request)
        XCTAssertEqual(body["url"] as? String, "https://images.example.com/photo.jpg")
        XCTAssertEqual(body["device_ids"] as? [String], ["picpak-kitchen"])
        XCTAssertEqual(body["fit"] as? String, "fill")
        XCTAssertEqual(body["override_quiet_hours"] as? Bool, true)
    }

    func testWebpagePushUsesContractEndpointAndViewport() async throws {
        let transport = RecordingLinkPushTransport(
            response: try acceptedJobResponse(kind: .webpagePush)
        )
        let client = try await makeClient(transport: transport)

        let job = try await client.sendWebpage(
            url: try XCTUnwrap(URL(string: "https://example.com/news")),
            fit: .blur,
            viewportW: 1_280,
            deviceIDs: ["picpak-kitchen", "e1004-desk"],
            overrideQuietHours: false,
            idempotencyKey: "webpage-idempotency-000001",
            instance: instance
        )

        XCTAssertEqual(job.kind, .webpagePush)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/webpages")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "webpage-idempotency-000001"
        )
        let body = try decodeJSONBody(request)
        XCTAssertEqual(body["url"] as? String, "https://example.com/news")
        XCTAssertEqual(
            body["device_ids"] as? [String],
            ["picpak-kitchen", "e1004-desk"]
        )
        XCTAssertEqual(body["fit"] as? String, "blur")
        XCTAssertEqual(body["viewport_w"] as? Int, 1_280)
        XCTAssertEqual(body["override_quiet_hours"] as? Bool, false)
    }

    func testLinkPushRejectsEmptyTargetsBeforeTransport() async throws {
        let transport = RecordingLinkPushTransport(
            response: try acceptedJobResponse(kind: .imageURLPush)
        )
        let client = try await makeClient(transport: transport)

        do {
            _ = try await client.sendImageURL(
                url: try XCTUnwrap(URL(string: "https://images.example.com/photo.jpg")),
                fit: .fit,
                deviceIDs: [],
                overrideQuietHours: false,
                idempotencyKey: "image-url-idempotency-0002",
                instance: instance
            )
            XCTFail("Expected noTargets")
        } catch {
            XCTAssertEqual(error as? TesseraeClientError, .noTargets)
        }
        let capturedRequest = await transport.lastRequest()
        XCTAssertNil(capturedRequest)
    }

    private func makeClient(
        transport: RecordingLinkPushTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(
            token: "tc_link_push_test",
            for: instance.id
        )
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.1.0",
                installationID: "link-push-test-installation"
            ),
            transport: transport
        )
    }

    private func acceptedJobResponse(
        kind: PushJobKind
    ) throws -> TesseraeHTTPResponse {
        let now = Date(timeIntervalSince1970: 1_754_041_200)
        let response = JobResponse(
            job: PushJob(
                id: "job_link_push_test",
                kind: kind,
                status: .accepted,
                targetDeviceIDs: ["picpak-kitchen"],
                createdAt: now,
                updatedAt: now
            )
        )
        return TesseraeHTTPResponse(
            data: try TesseraeJSON.encoder().encode(response),
            statusCode: 202
        )
    }

    private func decodeJSONBody(
        _ request: URLRequest
    ) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: try XCTUnwrap(request.httpBody)
            ) as? [String: Any]
        )
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.209.0",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }
}

private actor RecordingLinkPushTransport: TesseraeHTTPTransporting {
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
