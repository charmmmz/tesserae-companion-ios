import Foundation
import XCTest
@testable import TesseraeKit

final class GalleryClientTests: XCTestCase {
    func testGalleryFixturesDecodeStoredTypesAndNormalizedFolderName() throws {
        let folderData = try Data(
            contentsOf: fixtureURL("gallery-folder-response.json")
        )
        let response = try TesseraeJSON.decoder().decode(
            GalleryFolderResponse.self,
            from: folderData
        )

        XCTAssertEqual(response.folder.name, "family")
        XCTAssertTrue(response.folder.writable)
        XCTAssertEqual(
            Set(response.images.map(\.contentType)),
            ["image/jpeg", "image/png", "image/gif", "image/bmp"]
        )

        let normalizedData = try Data(
            contentsOf: fixtureURL("gallery-image-upload-response.json")
        )
        let upload = try TesseraeJSON.decoder().decode(
            GalleryImageResponse.self,
            from: normalizedData
        )
        XCTAssertEqual(upload.image.contentType, "image/jpeg")
    }

    func testUploadUsesOneImagePartAndPreservesIdempotencyKey() async throws {
        let responseData = try Data(
            contentsOf: fixtureURL("gallery-image-upload-response.json")
        )
        let transport = RecordingGalleryTransport(
            response: TesseraeHTTPResponse(data: responseData, statusCode: 201)
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.uploadGalleryImage(
            folderID: "folder_family",
            data: Data("image-bytes".utf8),
            fileName: "photo.heic",
            contentType: "image/heic",
            idempotencyKey: "gallery-upload-test-0001",
            instance: instance
        )

        XCTAssertEqual(result.contentType, "image/jpeg")
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.url?.path,
            "/api/app/v1/gallery/folders/folder_family/images"
        )
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Idempotency-Key"),
            "gallery-upload-test-0001"
        )
        let contentType = try XCTUnwrap(
            request.value(forHTTPHeaderField: "Content-Type")
        )
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
        let body = String(
            decoding: try XCTUnwrap(request.httpBody),
            as: UTF8.self
        )
        XCTAssertTrue(body.contains("name=\"image\"; filename=\"photo.heic\""))
        XCTAssertTrue(body.contains("Content-Type: image/heic"))
        XCTAssertFalse(body.contains("name=\"request\""))
    }

    func testGalleryResourceIsAuthenticatedAndRevalidated() async throws {
        let transport = RecordingGalleryTransport(
            response: TesseraeHTTPResponse(
                data: Data("thumbnail".utf8),
                statusCode: 200,
                headers: ["etag": "\"gallery-thumb\""]
            )
        )
        let client = try await makeClient(transport: transport)

        let result = try await client.fetchGalleryResource(
            path: "/api/app/v1/gallery/images/image_one/thumbnail",
            ifNoneMatch: "\"old-thumb\"",
            instance: instance
        )

        XCTAssertEqual(
            result,
            .image(data: Data("thumbnail".utf8), eTag: "\"gallery-thumb\"")
        )
        let capturedRequest = await transport.lastRequest()
        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Authorization"),
            "Bearer tc_gallery_test"
        )
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "If-None-Match"),
            "\"old-thumb\""
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "image/*")
    }

    func testGalleryResourceRejectsOffOriginURLBeforeSendingToken() async throws {
        let transport = RecordingGalleryTransport(
            response: TesseraeHTTPResponse(data: Data(), statusCode: 200)
        )
        let client = try await makeClient(transport: transport)

        do {
            _ = try await client.fetchGalleryResource(
                path: "https://attacker.example/api/app/v1/gallery/images/x/content",
                ifNoneMatch: nil,
                instance: instance
            )
            XCTFail("Expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? TesseraeClientError, .invalidResponse)
        }
        let capturedRequest = await transport.lastRequest()
        XCTAssertNil(capturedRequest)
    }

    func testMockGalleryUploadIsIdempotentAndExternalFoldersStayReadOnly() async throws {
        let client = MockTesseraeClient(latency: .zero)
        let session = try await client.pair(
            baseURL: instance.baseURL,
            code: "123456",
            clientName: "Gallery Test"
        )

        let first = try await client.uploadGalleryImage(
            folderID: "folder_family",
            data: Data("photo".utf8),
            fileName: "photo.jpg",
            contentType: "image/jpeg",
            idempotencyKey: "same-gallery-key",
            instance: session.instance
        )
        let retry = try await client.uploadGalleryImage(
            folderID: "folder_family",
            data: Data("photo".utf8),
            fileName: "photo.jpg",
            contentType: "image/jpeg",
            idempotencyKey: "same-gallery-key",
            instance: session.instance
        )

        XCTAssertEqual(first.id, retry.id)
        let detail = try await client.fetchGalleryFolder(
            id: "folder_family",
            instance: session.instance
        )
        XCTAssertEqual(detail.images.filter { $0.id == first.id }.count, 1)

        do {
            _ = try await client.uploadGalleryImage(
                folderID: "folder_archive",
                data: Data("photo".utf8),
                fileName: "photo.jpg",
                contentType: "image/jpeg",
                idempotencyKey: "read-only-gallery-key",
                instance: session.instance
            )
            XCTFail("Expected a read-only conflict")
        } catch let TesseraeClientError.server(code, _, _) {
            XCTAssertEqual(code, "gallery_folder_read_only")
        }
    }

    private func makeClient(
        transport: RecordingGalleryTransport
    ) async throws -> LiveTesseraeClient {
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "tc_gallery_test", for: instance.id)
        return LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: "0.7.0",
                installationID: "gallery-test-installation"
            ),
            transport: transport
        )
    }

    private var instance: TesseraeInstance {
        TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "https://tesserae.example")!,
            serverVersion: "0.300.0",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example/"
        )
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "../../../../Contracts/Fixtures")
            .appending(path: name)
            .standardizedFileURL
    }
}

private actor RecordingGalleryTransport: TesseraeHTTPTransporting {
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
