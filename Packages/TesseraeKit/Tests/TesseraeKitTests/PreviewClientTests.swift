import Foundation
import XCTest
@testable import TesseraeKit

final class PreviewClientTests: XCTestCase {
    func testDevicePreviewUsesBearerAndReturnsImageWithETag() async throws {
        let transport = RecordingPreviewTransport(
            response: TesseraeHTTPResponse(
                data: Data("png-data".utf8),
                statusCode: 200,
                headers: ["etag": "\"composition-digest\""]
            )
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.fetchDevicePreview(
            id: "display-one",
            ifNoneMatch: nil,
            instance: instance
        )

        XCTAssertEqual(
            result,
            .image(
                data: Data("png-data".utf8),
                eTag: "\"composition-digest\""
            )
        )
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/devices/display-one/preview"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_preview_test"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Accept"),
            "image/png"
        )
    }

    func testDevicePreviewRevalidatesWithETagAndHandles304() async throws {
        let transport = RecordingPreviewTransport(
            response: TesseraeHTTPResponse(
                data: Data(),
                statusCode: 304,
                headers: ["etag": "\"composition-digest\""]
            )
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.fetchDevicePreview(
            id: "display-one",
            ifNoneMatch: "\"composition-digest\"",
            instance: instance
        )

        XCTAssertEqual(result, .notModified)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-None-Match"),
            "\"composition-digest\""
        )
    }

    func testDashboardPreviewCarriesTargetAndPreparingDelay() async throws {
        let transport = RecordingPreviewTransport(
            response: TesseraeHTTPResponse(
                data: Data(),
                statusCode: 202,
                headers: ["retry-after": "2"]
            )
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.fetchDashboardPreview(
            id: "pantry",
            deviceID: "display-one",
            ifNoneMatch: nil,
            instance: instance
        )

        XCTAssertEqual(result, .preparing(retryAfterSeconds: 2))
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems,
            [URLQueryItem(name: "device_id", value: "display-one")]
        )
    }

    func testMissingPreviewIsAnOptionalNotFoundResult() async throws {
        let transport = RecordingPreviewTransport(
            response: TesseraeHTTPResponse(
                data: Data(),
                statusCode: 404
            )
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.fetchDashboardPreview(
            id: "unknown",
            deviceID: nil,
            ifNoneMatch: nil,
            instance: instance
        )

        XCTAssertEqual(result, .notFound)
    }

    private func makeClient(
        transport: RecordingPreviewTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(
            token: "tc_preview_test",
            for: instance.id
        )
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.1.0",
                installationID: "preview-test-installation"
            ),
            transport: transport
        )
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.208.0",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }
}

private actor RecordingPreviewTransport: TesseraeHTTPTransporting {
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
