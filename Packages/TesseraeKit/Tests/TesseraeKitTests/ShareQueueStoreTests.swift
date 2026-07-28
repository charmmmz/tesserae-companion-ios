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

    private var fixtureRequest: SharedImageRequest {
        SharedImageRequest(
            id: "request-1",
            instanceID: "instance-home",
            fileName: "shared-photo.jpg",
            contentType: "image/jpeg",
            fit: .fill,
            deviceIDs: ["picpak-fridge"],
            idempotencyKey: "idempotency-1",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
    }
}
