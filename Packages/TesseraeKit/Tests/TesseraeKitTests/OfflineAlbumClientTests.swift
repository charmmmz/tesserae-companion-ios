import Foundation
import XCTest
@testable import TesseraeKit

final class OfflineAlbumClientTests: XCTestCase {
    func testFixturesDecodeCapabilityScopeLimitsAndObservedState() throws {
        let capabilities = try decode(
            ServerCapabilities.self,
            fixture: "capabilities-offline-albums.json"
        )
        let authorization = try decode(
            CompanionSessionAuthorization.self,
            fixture: "session-authorization-offline-albums.json"
        )
        let devices = try decode(
            DevicesResponse.self,
            fixture: "devices-offline-albums-response.json"
        )
        let response = try decode(
            OfflineAlbumResponse.self,
            fixture: "offline-album-response.json"
        )

        XCTAssertTrue(capabilities.supportsGallery)
        XCTAssertTrue(capabilities.supportsOfflineAlbums)
        XCTAssertTrue(authorization.canWriteOfflineAlbums)

        let supported = try XCTUnwrap(
            devices.devices.first { $0.id == "e1004-desk" }?.frameCacheSupport
        )
        XCTAssertEqual(supported.state, .supported)
        XCTAssertEqual(supported.frameCacheCapacityBytes, 67_108_864)
        XCTAssertEqual(supported.frameCacheMaxFrames, 32)

        let unknown = try XCTUnwrap(
            devices.devices.first { $0.id == "e1004-hallway" }?.frameCacheSupport
        )
        XCTAssertEqual(unknown.state, .unknown)
        XCTAssertNil(unknown.detail)

        XCTAssertEqual(response.album.order, ["image_family_02", "image_family_01"])
        XCTAssertNotEqual(response.album.id, response.album.folderID)
        XCTAssertEqual(response.targets[0].plan?.accuracy, .exact)
        XCTAssertEqual(response.targets[0].plan?.storage?.accuracy, .exact)
        XCTAssertEqual(response.targets[0].observed?.state, .playing)
        XCTAssertEqual(response.targets[0].observed?.cached, 4)
    }

    func testDraftRoundTripsContractKeysWithoutInventingCapacity() throws {
        let fixtureData = try fixtureData("offline-album-draft.json")
        let draft = try TesseraeJSON.decoder().decode(
            OfflineAlbumDraft.self,
            from: fixtureData
        )
        let encoded = try TesseraeJSON.encoder().encode(draft)

        XCTAssertEqual(draft.playback.intervalSeconds, 1_800)
        XCTAssertEqual(draft.playback.repeatMode, .reshuffle)
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: encoded) as? NSDictionary,
            try JSONSerialization.jsonObject(with: fixtureData) as? NSDictionary
        )
    }

    func testPreflightUsesNestedNonMutatingEndpoint() async throws {
        let responseData = try fixtureData("offline-album-preflight-response.json")
        let transport = RecordingOfflineAlbumTransport(
            response: TesseraeHTTPResponse(data: responseData, statusCode: 200)
        )
        let client = try await makeClient(transport: transport)
        let draft = try decode(
            OfflineAlbumDraft.self,
            fixture: "offline-album-draft.json"
        )

        let response = try await client.preflightOfflineAlbum(
            folderID: "folder_family",
            draft: draft,
            instance: instance
        )

        XCTAssertEqual(response.folderID, "folder_family")
        XCTAssertEqual(response.targets[0].conflict?.albumID, "oa_7f92a4")
        XCTAssertEqual(response.targets[0].conflict?.name, "Holidays")
        XCTAssertEqual(response.targets[1].support.state, .unknown)
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/gallery/folders/folder_family/offline-album/preflight"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? NSDictionary,
            try JSONSerialization.jsonObject(
                with: fixtureData("offline-album-draft.json")
            ) as? NSDictionary
        )
    }

    func testPutEncodesExplicitTakeoverAndMapsConflictClaims() async throws {
        let requestBody = try decode(
            OfflineAlbumWriteRequest.self,
            fixture: "offline-album-put-request.json"
        )
        let errorData = try fixtureData("error-offline-album-conflict.json")
        let transport = RecordingOfflineAlbumTransport(
            response: TesseraeHTTPResponse(data: errorData, statusCode: 409)
        )
        let client = try await makeClient(transport: transport)

        do {
            _ = try await client.putOfflineAlbum(
                folderID: "folder_family",
                request: requestBody,
                eTag: "\"offline-album-1\"",
                instance: instance
            )
            XCTFail("Expected an explicit Offline Album conflict")
        } catch let TesseraeClientError.offlineAlbumConflict(
            claims,
            message,
            requestID
        ) {
            XCTAssertEqual(
                claims,
                [
                    "e1004-desk": OfflineAlbumConflictClaim(
                        albumID: "oa_7f92a4",
                        name: "Holidays"
                    ),
                ]
            )
            XCTAssertTrue(message.contains("another Offline Album"))
            XCTAssertEqual(requestID, "req_offline_album_conflict")
        }

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-Match"),
            "\"offline-album-1\""
        )
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/gallery/folders/folder_family/offline-album"
        )
        XCTAssertEqual(
            try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody))
                as? NSDictionary,
            try JSONSerialization.jsonObject(
                with: fixtureData("offline-album-put-request.json")
            ) as? NSDictionary
        )
    }

    func testDeleteUsesNestedResourceAndNoJob() async throws {
        let transport = RecordingOfflineAlbumTransport(
            response: TesseraeHTTPResponse(data: Data(), statusCode: 204)
        )
        let client = try await makeClient(transport: transport)

        try await client.deleteOfflineAlbum(
            folderID: "folder_family",
            instance: instance
        )

        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/gallery/folders/folder_family/offline-album"
        )
    }

    func testFetchRequiresETagAndAllowsPartialDeviceObservation() async throws {
        let responseData = try fixtureData(
            "offline-album-response-partial-observation.json"
        )
        let transport = RecordingOfflineAlbumTransport(
            response: TesseraeHTTPResponse(
                data: responseData,
                statusCode: 200,
                headers: ["etag": "\"offline-album-4\""]
            )
        )
        let client = try await makeClient(transport: transport)

        let versioned = try await client.fetchOfflineAlbum(
            folderID: "folder_family",
            instance: instance
        )

        XCTAssertEqual(versioned.eTag, "\"offline-album-4\"")
        let observed = try XCTUnwrap(
            versioned.response.targets.first?.observed
        )
        XCTAssertEqual(observed.state, .playing)
        XCTAssertNil(observed.cached)
        XCTAssertNil(observed.total)
        XCTAssertNil(observed.version)
    }

    func testSuccessfulPutReturnsNewETag() async throws {
        let transport = RecordingOfflineAlbumTransport(
            response: TesseraeHTTPResponse(
                data: try fixtureData("offline-album-response.json"),
                statusCode: 200,
                headers: ["ETag": "\"offline-album-5\""]
            )
        )
        let client = try await makeClient(transport: transport)
        let requestBody = try decode(
            OfflineAlbumWriteRequest.self,
            fixture: "offline-album-put-request.json"
        )

        let versioned = try await client.putOfflineAlbum(
            folderID: "folder_family",
            request: requestBody,
            eTag: "\"offline-album-4\"",
            instance: instance
        )

        XCTAssertEqual(versioned.eTag, "\"offline-album-5\"")
        XCTAssertEqual(versioned.response.album.id, "oa_4c6d9e")
    }

    func testMockRefusesUnsupportedButAllowsUnknownTargets() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let draft = OfflineAlbumDraft(
            name: "Family",
            enabled: true,
            deviceIDs: ["future-display"],
            order: ["image_family_01"],
            fit: .fill,
            playback: OfflineAlbumPlayback(
                mode: .sequential,
                intervalSeconds: 600,
                repeatMode: .loop
            )
        )
        let preflight = try await client.preflightOfflineAlbum(
            folderID: "folder_family",
            draft: draft,
            instance: instance
        )
        XCTAssertEqual(preflight.targets[0].support.state, .unknown)
        let saved = try await client.putOfflineAlbum(
            folderID: "folder_family",
            request: OfflineAlbumWriteRequest(album: draft),
            eTag: nil,
            instance: instance
        )

        let unsupported = OfflineAlbumDraft(
            name: "Family",
            enabled: true,
            deviceIDs: ["picpak-kitchen"],
            order: [],
            fit: .fit,
            playback: draft.playback
        )
        do {
            _ = try await client.putOfflineAlbum(
                folderID: "folder_family",
                request: OfflineAlbumWriteRequest(album: unsupported),
                eTag: saved.eTag,
                instance: instance
            )
            XCTFail("Expected unsupported target refusal")
        } catch let TesseraeClientError.offlineAlbumUnsupportedTargets(
            deviceIDs,
            _,
            _
        ) {
            XCTAssertEqual(deviceIDs, ["picpak-kitchen"])
        }
    }

    func testMockRequiresETagAndNormalizesDeletedOrderEntries() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let draft = OfflineAlbumDraft(
            name: "Family",
            enabled: true,
            deviceIDs: ["e1004-desk"],
            order: ["image_family_01", "deleted_image"],
            fit: .fill,
            playback: OfflineAlbumPlayback(
                mode: .sequential,
                intervalSeconds: 600,
                repeatMode: .loop
            )
        )
        let created = try await client.putOfflineAlbum(
            folderID: "folder_family",
            request: OfflineAlbumWriteRequest(album: draft),
            eTag: nil,
            instance: instance
        )
        XCTAssertEqual(created.response.album.order, ["image_family_01"])

        do {
            _ = try await client.putOfflineAlbum(
                folderID: "folder_family",
                request: OfflineAlbumWriteRequest(album: draft),
                eTag: nil,
                instance: instance
            )
            XCTFail("Expected missing If-Match to refuse an update")
        } catch let TesseraeClientError.server(code, _, _) {
            XCTAssertEqual(code, "precondition_failed")
        }

        let updated = try await client.putOfflineAlbum(
            folderID: "folder_family",
            request: OfflineAlbumWriteRequest(album: draft),
            eTag: created.eTag,
            instance: instance
        )
        XCTAssertNotEqual(updated.eTag, created.eTag)
    }

    private func makeClient(
        transport: RecordingOfflineAlbumTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "tc_offline_album_test", for: instance.id)
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.7.0",
                installationID: "offline-album-test-installation"
            ),
            transport: transport
        )
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.303.0",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        fixture: String
    ) throws -> Value {
        try TesseraeJSON.decoder().decode(type, from: fixtureData(fixture))
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures")
            .appending(path: name)
            .standardizedFileURL
    }
}

private actor RecordingOfflineAlbumTransport: TesseraeHTTPTransporting {
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
