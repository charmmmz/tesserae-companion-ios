import Foundation
import XCTest
@testable import TesseraeKit

final class LiveTesseraeClientTests: XCTestCase {
    func testFixtureServerVerticalSlice() async throws {
        guard
            let value = ProcessInfo.processInfo.environment["TESSERAE_FIXTURE_BASE_URL"],
            let baseURL = URL(string: value)
        else {
            throw XCTSkip("Set TESSERAE_FIXTURE_BASE_URL to run live transport integration.")
        }

        let credentials = InMemoryCredentialStore()
        let client = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.1.0",
                installationID: "swift-integration-test-0001"
            )
        )

        let capabilities = try await client.probe(baseURL: baseURL)
        XCTAssertEqual(capabilities.api.version, 1)
        XCTAssertTrue(capabilities.features.contains("jobs"))
        XCTAssertTrue(capabilities.features.contains("history"))
        XCTAssertTrue(capabilities.features.contains("image_url_push"))
        XCTAssertTrue(capabilities.features.contains("webpage_push"))
        XCTAssertEqual(
            capabilities.limits.imageFitModes,
            ImageFitMode.allCases
        )

        let session = try await client.pair(
            baseURL: baseURL,
            code: "482193",
            clientName: "Swift Integration Test"
        )
        await credentials.save(
            token: session.token,
            for: session.instance.id
        )

        let displays = try await client.fetchDisplays(instance: session.instance)
        let dashboards = try await client.fetchDashboards(instance: session.instance)
        XCTAssertEqual(displays.first?.id, "picpak-kitchen")
        XCTAssertEqual(dashboards.first?.id, "pantry")

        let accepted = try await client.pushDashboard(
            id: "pantry",
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "swift-dashboard-test-0001",
            instance: session.instance
        )
        XCTAssertEqual(accepted.status, .accepted)

        let completed = try await client.fetchJob(
            id: accepted.id,
            instance: session.instance
        )
        XCTAssertEqual(completed.status, .succeeded)
        XCTAssertEqual(completed.result?.status, .published)

        let image = try await client.sendImage(
            data: Data("fixture-image".utf8),
            fileName: "fixture.jpg",
            contentType: "image/jpeg",
            fit: .fill,
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "swift-image-test-0000001",
            instance: session.instance
        )
        XCTAssertEqual(image.kind, .imagePush)
        XCTAssertEqual(image.status, .accepted)

        let imageURL = try await client.sendImageURL(
            url: try XCTUnwrap(URL(string: "https://images.example.com/photo.jpg")),
            fit: .fill,
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "swift-image-url-test-0001",
            instance: session.instance
        )
        XCTAssertEqual(imageURL.kind, .imageURLPush)
        XCTAssertEqual(imageURL.status, .accepted)

        let webpage = try await client.sendWebpage(
            url: try XCTUnwrap(URL(string: "https://example.com/news")),
            fit: .fit,
            viewportW: 1_280,
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "swift-webpage-test-00001",
            instance: session.instance
        )
        XCTAssertEqual(webpage.kind, .webpagePush)
        XCTAssertEqual(webpage.status, .accepted)

        let history = try await client.fetchHistory(
            beforeID: nil,
            limit: 30,
            instance: session.instance
        )
        let photo = try XCTUnwrap(history.items.first)
        XCTAssertEqual(photo.fit, .blur)

        let preview = try await client.fetchHistoryPreview(
            id: photo.id,
            ifNoneMatch: nil,
            instance: session.instance
        )
        guard case let .image(data, eTag) = preview else {
            return XCTFail("Expected a History preview image.")
        }
        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(eTag, "\"history-preview-fixture\"")

        let resend = try await client.resendHistory(
            id: photo.id,
            overrideQuietHours: false,
            idempotencyKey: "swift-history-resend-0001",
            instance: session.instance
        )
        let resent = try await client.fetchJob(
            id: resend.id,
            instance: session.instance
        )
        XCTAssertEqual(resend.kind, .historyResend)
        XCTAssertNotNil(resent.result?.historyEventIDs)

        try await client.revokeSession(instance: session.instance)
    }
}
