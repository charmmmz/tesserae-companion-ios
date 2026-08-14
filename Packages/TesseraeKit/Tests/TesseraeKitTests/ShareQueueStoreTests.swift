import Foundation
import XCTest
@testable import TesseraeKit

final class ShareQueueStoreTests: XCTestCase {
    func testPersistsUpdatesAndRemovesQueuedImage() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TesseraeShareQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShareQueueStore(directoryURL: directory)
        let request = fixtureRequest
        let image = Data("fixture-image".utf8)

        try await store.enqueue(imageData: image, request: request)
        let queued = try await store.requests()
        let restoredImage = try await store.imageData(for: request)
        XCTAssertEqual(queued, [request])
        XCTAssertEqual(restoredImage, image)

        let failed = request.updating(
            status: .failed,
            error: "fixture offline",
            at: Date(timeIntervalSince1970: 20)
        )
        try await store.update(failed)
        let failedRequests = try await store.requests()
        XCTAssertEqual(failedRequests, [failed])

        try await store.remove(failed)
        let removedRequests = try await store.requests()
        XCTAssertEqual(removedRequests, [])
    }

    func testPurgeDeletesExpiredImageAndMetadata() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TesseraeShareQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShareQueueStore(directoryURL: directory)
        let request = fixtureRequest
        try await store.enqueue(
            imageData: Data("fixture-image".utf8),
            request: request
        )

        try await store.purge(
            expiredBefore: Date(timeIntervalSince1970: 11)
        )

        let remaining = try await store.requests()
        XCTAssertEqual(remaining, [])
        do {
            _ = try await store.imageData(for: request)
            XCTFail("Expected the queued image to be removed.")
        } catch {
            XCTAssertEqual(error as? ShareQueueStoreError, .missingImage)
        }
    }

    func testSameImageCanQueueAndRemoveIndependentAspectGroups() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TesseraeShareQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = FileShareQueueStore(directoryURL: directory)
        let image = Data("fixture-image".utf8)
        let portrait = SharedImageRequest(
            id: "request-portrait",
            instanceID: "instance-home",
            fileName: "shared-photo.jpg",
            contentType: "image/jpeg",
            fit: .fill,
            framing: ImageFraming(focusX: 0.42, focusY: 0.55, zoom: 1.4),
            deviceIDs: ["display-portrait"],
            idempotencyKey: "idempotency-portrait",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let landscape = SharedImageRequest(
            id: "request-landscape",
            instanceID: "instance-home",
            fileName: "shared-photo.jpg",
            contentType: "image/jpeg",
            fit: .fill,
            framing: ImageFraming(focusX: 0.68, focusY: 0.38, zoom: 1.8),
            deviceIDs: ["display-landscape-a", "display-landscape-b"],
            idempotencyKey: "idempotency-landscape",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )

        try await store.enqueue(imageData: image, request: portrait)
        try await store.enqueue(imageData: image, request: landscape)
        let queued = try await store.requests()
        let portraitImage = try await store.imageData(for: portrait)
        let landscapeImage = try await store.imageData(for: landscape)
        XCTAssertEqual(
            Set(queued),
            Set([portrait, landscape])
        )
        XCTAssertEqual(portraitImage, image)
        XCTAssertEqual(landscapeImage, image)

        try await store.remove(portrait)
        let remaining = try await store.requests()
        let remainingImage = try await store.imageData(for: landscape)
        XCTAssertEqual(remaining, [landscape])
        XCTAssertEqual(remainingImage, image)
    }

    func testReadsLegacyQueuedImageWithoutFraming() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TesseraeShareQueueTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let queueDirectory = directory.appending(
            path: "ShareQueue",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: queueDirectory,
            withIntermediateDirectories: true
        )

        let encoded = try TesseraeJSON.encoder().encode(fixtureRequest)
        var legacyJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        legacyJSON.removeValue(forKey: "framing")
        try JSONSerialization.data(withJSONObject: legacyJSON).write(
            to: queueDirectory.appending(path: "request-1.json")
        )

        let restored = try await FileShareQueueStore(
            directoryURL: directory
        ).requests()
        XCTAssertEqual(restored.count, 1)
        XCTAssertNil(restored.first?.framing)
    }

    private var fixtureRequest: SharedImageRequest {
        SharedImageRequest(
            id: "request-1",
            instanceID: "instance-home",
            fileName: "shared-photo.jpg",
            contentType: "image/jpeg",
            fit: .fill,
            framing: ImageFraming(
                focusX: 0.62,
                focusY: 0.38,
                zoom: 1.5
            ),
            deviceIDs: ["picpak-fridge"],
            idempotencyKey: "idempotency-1",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
