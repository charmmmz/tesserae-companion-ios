import Foundation
import XCTest
@testable import TesseraeKit

final class CompanionCompatibilityTests: XCTestCase {
    func testAcceptsCompleteVersionOneCapabilities() throws {
        XCTAssertNoThrow(
            try CompanionCompatibility.validate(fixtureCapabilities)
        )
    }

    func testRejectsMissingWriteFeature() throws {
        let incomplete = ServerCapabilities(
            product: fixtureCapabilities.product,
            serverVersion: fixtureCapabilities.serverVersion,
            api: fixtureCapabilities.api,
            pairing: fixtureCapabilities.pairing,
            features: ["devices", "dashboards", "jobs"],
            limits: fixtureCapabilities.limits,
            webURL: fixtureCapabilities.webURL
        )

        do {
            try CompanionCompatibility.validate(incomplete)
            XCTFail("Expected missing features.")
        } catch {
            XCTAssertEqual(
                error as? TesseraeClientError,
                .missingFeatures(["dashboard_push", "image_push"])
            )
        }
    }

    func testAcceptsOptionalPreviewExtension() throws {
        let extended = ServerCapabilities(
            product: fixtureCapabilities.product,
            serverVersion: "0.208.0",
            api: fixtureCapabilities.api,
            pairing: fixtureCapabilities.pairing,
            features: fixtureCapabilities.features.union(["previews"]),
            limits: fixtureCapabilities.limits,
            webURL: fixtureCapabilities.webURL
        )

        XCTAssertNoThrow(
            try CompanionCompatibility.validate(extended)
        )
        XCTAssertFalse(
            CompanionCompatibility.requiredFeatures.contains("previews")
        )
    }

    func testResolvesRelativeInstanceAndDashboardWebURLs() async throws {
        let credentials = InMemoryCredentialStore()
        let transport = StaticTransport(
            responses: [
                "/api/app/v1/pair": TesseraeHTTPResponse(
                    data: Data(pairResponse.utf8),
                    statusCode: 201
                ),
                "/api/app/v1/dashboards": TesseraeHTTPResponse(
                    data: Data(dashboardsResponse.utf8),
                    statusCode: 200
                ),
            ]
        )
        let client = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.1.0",
                installationID: "compatibility-test-installation"
            ),
            transport: transport
        )

        let session = try await client.pair(
            baseURL: URL(string: "http://tesserae.local:8765")!,
            code: "482193",
            clientName: "Test iPhone"
        )
        XCTAssertEqual(
            session.instance.webURL,
            "http://tesserae.local:8765/"
        )

        await credentials.save(
            token: session.token,
            for: session.instance.id
        )
        let dashboards = try await client.fetchDashboards(
            instance: session.instance
        )
        XCTAssertEqual(
            dashboards.first?.webURL,
            "http://tesserae.local:8765/pages/pantry"
        )
    }

    private var fixtureCapabilities: ServerCapabilities {
        ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.207.0",
            api: CompanionAPI(version: 1),
            pairing: PairingCapabilities(
                supported: true,
                codeLength: 6,
                ttlSeconds: 600
            ),
            features: CompanionCompatibility.requiredFeatures,
            limits: CompanionLimits(
                imageUploadBytes: 26_214_400,
                imageMaxEdge: 8_192,
                imageContentTypes: ["image/jpeg"],
                jobRetentionSeconds: 86_400,
                idempotencyRetentionSeconds: 86_400
            ),
            webURL: "/"
        )
    }

    private var pairResponse: String {
        """
        {
          "token": "tc_test_token",
          "token_id": "ct_test",
          "scopes": ["devices:read", "dashboards:read", "push:write", "media:write"],
          "created_at": "2026-07-28T08:00:00Z",
          "instance": {
            "id": "inst_test",
            "name": "Home",
            "server_version": "0.207.0",
            "timezone": "Asia/Shanghai",
            "web_url": "/"
          }
        }
        """
    }

    private var dashboardsResponse: String {
        """
        {
          "dashboards": [{
            "id": "pantry",
            "name": "Pantry",
            "kind": "grid",
            "device_ids": ["picpak-kitchen"],
            "updated_at": "2026-07-28T08:00:00Z",
            "web_url": "/pages/pantry"
          }]
        }
        """
    }
}

private actor StaticTransport: TesseraeHTTPTransporting {
    let responses: [String: TesseraeHTTPResponse]

    init(responses: [String: TesseraeHTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) throws -> TesseraeHTTPResponse {
        guard let response = responses[request.url?.path ?? ""] else {
            throw TesseraeClientError.invalidResponse
        }
        return response
    }
}
