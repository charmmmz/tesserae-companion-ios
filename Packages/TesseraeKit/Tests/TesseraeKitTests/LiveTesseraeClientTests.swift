import Foundation
import XCTest
@testable import TesseraeKit

final class LiveTesseraeClientTests: XCTestCase {
    func testDevicePairingUsesAuthenticatedCompanionEndpoint() async throws {
        let response = """
        {
          "code": "482917",
          "expires_at": "2026-08-17T03:45:00Z"
        }
        """
        let transport = RecordingDeviceSetupTransport(
            response: TesseraeHTTPResponse(
                data: Data(response.utf8),
                statusCode: 201
            )
        )
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "companion-secret", for: "home")
        let client = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.6.3",
                installationID: "device-setup-test"
            ),
            transport: transport
        )
        let instance = TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: try XCTUnwrap(URL(string: "http://tesserae.local:5000")),
            serverVersion: "0.310.0",
            timezone: "Asia/Shanghai",
            webURL: "/"
        )

        let pairing = try await client.createFirmwareDevicePairing(
            instance: instance
        )

        XCTAssertEqual(pairing.code, "482917")
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.url?.path, "/api/app/v1/device-pairings")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer companion-secret"
        )
    }

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
        XCTAssertTrue(capabilities.features.contains("image_framing"))
        XCTAssertTrue(capabilities.features.contains("lineups"))
        XCTAssertTrue(capabilities.features.contains("lineup_control"))
        XCTAssertTrue(capabilities.supportsGallery)
        XCTAssertEqual(capabilities.limits.imageFramingMaxZoom, 4)
        XCTAssertEqual(capabilities.limits.galleryUploadBatchSize, 20)
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

        let galleryFolders = try await client.fetchGalleryFolders(
            instance: session.instance
        )
        XCTAssertEqual(galleryFolders.first?.id, "folder_family")
        let galleryFolder = try await client.fetchGalleryFolder(
            id: "folder_family",
            instance: session.instance
        )
        let galleryImage = try XCTUnwrap(galleryFolder.images.first)
        XCTAssertEqual(galleryImage.folderID, "folder_family")
        let galleryThumbnail = try await client.fetchGalleryResource(
            path: galleryImage.thumbnailURL,
            ifNoneMatch: nil,
            instance: session.instance
        )
        guard case .image = galleryThumbnail else {
            return XCTFail("Expected a Gallery thumbnail.")
        }
        let createdFolder = try await client.createGalleryFolder(
            name: "Summer 2026!",
            instance: session.instance
        )
        XCTAssertEqual(createdFolder.folder.name, "summer-2026")
        let uploadedGalleryImage = try await client.uploadGalleryImage(
            folderID: createdFolder.folder.id,
            data: Data("gallery-fixture-image".utf8),
            fileName: "holiday.heic",
            contentType: "image/heic",
            idempotencyKey: "swift-gallery-upload-0001",
            instance: session.instance
        )
        XCTAssertEqual(uploadedGalleryImage.contentType, "image/jpeg")

        let lineups = try await client.fetchLineups(instance: session.instance)
        XCTAssertEqual(lineups.first?.id, "kitchen-deck")
        XCTAssertEqual(lineups.last?.nativeEditable, false)
        XCTAssertFalse(lineups.last?.dashboards.first?.conditions?.isEmpty ?? true)

        let lineup = try await client.fetchLineup(
            id: "kitchen-deck",
            instance: session.instance
        )
        XCTAssertEqual(lineup.current.first?.pageID, "pantry")

        let lineupJob = try await client.controlLineup(
            id: "kitchen-deck",
            action: .play,
            pageID: "morning",
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "swift-lineup-action-0001",
            instance: session.instance
        )
        XCTAssertEqual(lineupJob.kind, .lineupAction)

        let disabledLineup = try await client.setLineupEnabled(
            id: "kitchen-deck",
            enabled: false,
            instance: session.instance
        )
        XCTAssertFalse(disabledLineup.enabled)

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
            framing: ImageFraming(
                focusX: 0.62,
                focusY: 0.38,
                zoom: 1.35
            ),
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
        XCTAssertEqual(photo.fit, .fill)
        XCTAssertEqual(
            photo.framing,
            ImageFraming(focusX: 0.62, focusY: 0.38, zoom: 1.35)
        )

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

private actor RecordingDeviceSetupTransport: TesseraeHTTPTransporting {
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
