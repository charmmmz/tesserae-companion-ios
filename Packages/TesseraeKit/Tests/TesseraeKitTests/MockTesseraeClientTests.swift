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
        XCTAssertTrue(capabilities.features.contains("image_url_push"))
        XCTAssertTrue(capabilities.features.contains("webpage_push"))
        XCTAssertEqual(capabilities.limits.imageMaxEdge, 8_192)
        XCTAssertTrue(capabilities.limits.imageContentTypes.contains("image/heic"))
        XCTAssertEqual(capabilities.limits.imageFitModes, ImageFitMode.allCases)
        XCTAssertTrue(capabilities.supportsImageFraming)
        XCTAssertEqual(capabilities.limits.imageFramingMaxZoom, 4)
        XCTAssertTrue(capabilities.features.contains("history"))
        XCTAssertTrue(capabilities.supports(.imageURL))
        XCTAssertTrue(capabilities.supports(.webpage))
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

    func testMockLinkPushesProduceCorrelatableJobs() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: baseURL,
            code: "123456",
            clientName: "Test iPhone"
        )

        let imageURL = try await client.sendImageURL(
            url: try XCTUnwrap(URL(string: "https://images.example.com/photo.jpg")),
            fit: .fill,
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: false,
            idempotencyKey: "mock-image-url-0001",
            instance: session.instance
        )
        let webpage = try await client.sendWebpage(
            url: try XCTUnwrap(URL(string: "https://example.com/news")),
            fit: .fit,
            viewportW: 1_280,
            deviceIDs: ["e1004-desk"],
            overrideQuietHours: false,
            idempotencyKey: "mock-webpage-00001",
            instance: session.instance
        )
        let completedImageURL = try await client.fetchJob(
            id: imageURL.id,
            instance: session.instance
        )
        let completedWebpage = try await client.fetchJob(
            id: webpage.id,
            instance: session.instance
        )

        XCTAssertEqual(imageURL.kind, .imageURLPush)
        XCTAssertEqual(webpage.kind, .webpagePush)
        XCTAssertEqual(
            completedImageURL.result?.historyEventIDs,
            ["history-demo-image-url"]
        )
        XCTAssertEqual(
            completedWebpage.result?.historyEventIDs,
            ["history-demo-webpage"]
        )
    }

    func testContractFixturesDecodeIntoSwiftModels() throws {
        let decoder = TesseraeJSON.decoder()

        let capabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities.json",
            decoder: decoder
        )
        let extendedCapabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities-extended.json",
            decoder: decoder
        )
        let framingCapabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities-framing.json",
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
        let basicImagePush = try decode(
            ImagePushRequest.self,
            fixture: "image-push-request-basic.json",
            decoder: decoder
        )
        let imageURLPush = try decode(
            ImageURLPushRequest.self,
            fixture: "image-url-push-request.json",
            decoder: decoder
        )
        let webpagePush = try decode(
            WebpagePushRequest.self,
            fixture: "webpage-push-request.json",
            decoder: decoder
        )
        let history = try decode(
            HistoryResponse.self,
            fixture: "history-response.json",
            decoder: decoder
        )
        let linkHistory = try decode(
            HistoryResponse.self,
            fixture: "history-link-response.json",
            decoder: decoder
        )
        let historyResendRequest = try decode(
            HistoryResendRequest.self,
            fixture: "history-resend-request.json",
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
        let historyResend = try decode(
            JobResponse.self,
            fixture: "job-history-resend.json",
            decoder: decoder
        )
        let imageURLPublished = try decode(
            JobResponse.self,
            fixture: "job-image-url-published.json",
            decoder: decoder
        )
        let webpagePublished = try decode(
            JobResponse.self,
            fixture: "job-webpage-published.json",
            decoder: decoder
        )
        let webpageBlocked = try decode(
            JobResponse.self,
            fixture: "job-webpage-blocked.json",
            decoder: decoder
        )
        let error = try decode(
            APIErrorResponse.self,
            fixture: "error-response.json",
            decoder: decoder
        )

        XCTAssertEqual(capabilities.api.version, 1)
        XCTAssertEqual(
            capabilities.limits.imageFitModes,
            ImageFitMode.legacyModes
        )
        XCTAssertEqual(
            extendedCapabilities.limits.imageFitModes,
            ImageFitMode.allCases
        )
        XCTAssertTrue(extendedCapabilities.features.contains("image_url_push"))
        XCTAssertTrue(extendedCapabilities.features.contains("webpage_push"))
        XCTAssertNil(extendedCapabilities.limits.imageFramingMaxZoom)
        XCTAssertFalse(extendedCapabilities.supportsImageFraming)
        XCTAssertTrue(framingCapabilities.features.contains("image_framing"))
        XCTAssertEqual(framingCapabilities.limits.imageFramingMaxZoom, 4)
        XCTAssertTrue(framingCapabilities.supportsImageFraming)
        XCTAssertEqual(pairRequest.client.installationID, "A1B2C3D4-E5F6-47A8-9012-3456789ABCDE")
        XCTAssertEqual(pairResponse.tokenID, "ct_01JABCDEF")
        XCTAssertEqual(devices.devices.first?.rssiDBM, -54)
        XCTAssertEqual(devices.devices.first?.iconName, "device-tablet")
        XCTAssertEqual(devices.devices.first?.hasPendingRender, true)
        XCTAssertEqual(
            devices.devices.first?.pendingRender?.revision,
            "a1b2c3d4e5f67890"
        )
        XCTAssertEqual(
            devices.devices.first?.pendingRender?.previewURL,
            "/api/app/v1/devices/picpak-kitchen/preview?revision=a1b2c3d4e5f67890"
        )
        XCTAssertEqual(devices.devices.last?.hasPendingRender, false)
        XCTAssertNil(devices.devices.last?.pendingRender)
        XCTAssertEqual(dashboards.dashboards.first?.deviceIDs, ["picpak-kitchen"])
        XCTAssertEqual(dashboards.dashboards.first?.iconName, "cooking-pot")
        XCTAssertNil(dashboards.dashboards.last?.iconName)
        XCTAssertEqual(dashboardPush.deviceIDs, ["picpak-kitchen"])
        XCTAssertEqual(imagePush.fit, .fill)
        XCTAssertEqual(
            imagePush.framing,
            ImageFraming(focusX: 0.62, focusY: 0.38, zoom: 1.35)
        )
        XCTAssertEqual(imagePush.deviceIDs.count, 2)
        XCTAssertEqual(basicImagePush.fit, .blur)
        XCTAssertNil(basicImagePush.framing)
        XCTAssertEqual(imageURLPush.url.host, "images.example.com")
        XCTAssertEqual(imageURLPush.fit, .fill)
        XCTAssertEqual(webpagePush.viewportW, 1_280)
        XCTAssertEqual(webpagePush.deviceIDs.count, 2)
        XCTAssertEqual(history.items.first?.fit, .fill)
        XCTAssertEqual(history.items.first?.framing, imagePush.framing)
        XCTAssertEqual(history.nextBeforeID, "history_0100")
        XCTAssertEqual(linkHistory.items.map(\.source), ["webpage", "url"])
        XCTAssertFalse(historyResendRequest.overrideQuietHours)
        XCTAssertEqual(accepted.job.status, .accepted)
        XCTAssertEqual(published.job.result?.status, .published)
        XCTAssertEqual(quiet.job.result?.status, .quiet)
        XCTAssertEqual(failed.job.error?.code, "render_failed")
        XCTAssertEqual(historyResend.job.kind, .historyResend)
        XCTAssertEqual(imageURLPublished.job.kind, .imageURLPush)
        XCTAssertEqual(webpagePublished.job.kind, .webpagePush)
        XCTAssertEqual(webpageBlocked.job.error?.code, "url_blocked")
        XCTAssertEqual(
            historyResend.job.result?.historyEventIDs,
            ["history_0103"]
        )
        XCTAssertEqual(error.error.requestID, "req_01JABCDEF")
    }

    func testMockHistoryResendProducesCorrelatableJob() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: baseURL,
            code: "123456",
            clientName: "Test iPhone"
        )

        let history = try await client.fetchHistory(
            beforeID: nil,
            limit: 1,
            instance: session.instance
        )
        let item = try XCTUnwrap(history.items.first)
        let accepted = try await client.resendHistory(
            id: item.id,
            overrideQuietHours: false,
            idempotencyKey: "mock-history-resend-0001",
            instance: session.instance
        )
        let completed = try await client.fetchJob(
            id: accepted.id,
            instance: session.instance
        )

        XCTAssertEqual(accepted.kind, .historyResend)
        XCTAssertEqual(
            completed.result?.historyEventIDs,
            ["history-demo-resent"]
        )
    }

    func testRequestModelsEncodeSnakeCaseKeys() throws {
        let encoder = TesseraeJSON.encoder()
        let dashboardRequest = DashboardPushRequest(
            deviceIDs: ["picpak-kitchen"],
            overrideQuietHours: true
        )
        let webpageRequest = WebpagePushRequest(
            url: try XCTUnwrap(URL(string: "https://example.com/news")),
            deviceIDs: ["picpak-kitchen"],
            fit: .fit,
            viewportW: 1_280
        )
        let imageRequest = ImagePushRequest(
            deviceIDs: ["picpak-kitchen"],
            fit: .fill,
            framing: ImageFraming(focusX: 0.62, focusY: 0.38, zoom: 1.35)
        )

        let dashboardJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(dashboardRequest)
            ) as? [String: Any]
        )
        let webpageJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(webpageRequest)
            ) as? [String: Any]
        )
        let imageJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: encoder.encode(imageRequest)
            ) as? [String: Any]
        )

        XCTAssertEqual(
            dashboardJSON["device_ids"] as? [String],
            ["picpak-kitchen"]
        )
        XCTAssertEqual(dashboardJSON["override_quiet_hours"] as? Bool, true)
        XCTAssertNil(dashboardJSON["deviceIds"])
        XCTAssertEqual(webpageJSON["url"] as? String, "https://example.com/news")
        XCTAssertEqual(webpageJSON["viewport_w"] as? Int, 1_280)
        XCTAssertEqual(webpageJSON["override_quiet_hours"] as? Bool, false)
        XCTAssertNil(webpageJSON["viewportW"])
        let framingJSON = try XCTUnwrap(
            imageJSON["framing"] as? [String: Double]
        )
        XCTAssertEqual(framingJSON["focus_x"], 0.62)
        XCTAssertEqual(framingJSON["focus_y"], 0.38)
        XCTAssertEqual(framingJSON["zoom"], 1.35)
        XCTAssertNil(framingJSON["focusX"])
    }

    func testOlderDeviceResponseMayOmitPendingRender() throws {
        let data = Data(
            """
            {
              "devices": [{
                "id": "legacy",
                "name": "Legacy",
                "kind": "pico_bin_client",
                "icon": "device-tablet",
                "panel": {
                  "width": 800,
                  "height": 480,
                  "gamut": "bw",
                  "orientation": "landscape"
                },
                "freshness": "unknown"
              }]
            }
            """.utf8
        )

        let response = try TesseraeJSON.decoder().decode(
            DevicesResponse.self,
            from: data
        )

        XCTAssertNil(response.devices.first?.hasPendingRender)
        XCTAssertNil(response.devices.first?.pendingRender)
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
