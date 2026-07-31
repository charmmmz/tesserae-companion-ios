import XCTest
@testable import TesseraeKit

final class LinkShareQueueStoreTests: XCTestCase {
    func testFileStorePersistsUpdatesAndRemovesQueuedLink() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileLinkShareQueueStore(directoryURL: directory)
        let request = SharedLinkRequest(
            instanceID: "home",
            url: try XCTUnwrap(URL(string: "https://example.com/news")),
            kind: .webpage,
            fit: .fit,
            deviceIDs: ["display-one"],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )

        try await store.enqueue(request)
        let enqueued = try await store.requests()
        XCTAssertEqual(enqueued, [request])

        let failed = request.updating(
            status: .failed,
            error: "temporarily offline",
            at: Date(timeIntervalSince1970: 110)
        )
        try await store.update(failed)
        let updated = try await store.requests()
        XCTAssertEqual(updated, [failed])

        try await store.remove(failed)
        let removed = try await store.requests()
        XCTAssertTrue(removed.isEmpty)
    }

    func testFileStorePurgesExpiredLinksOnly() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileLinkShareQueueStore(directoryURL: directory)
        let old = SharedLinkRequest(
            instanceID: "home",
            url: try XCTUnwrap(URL(string: "https://example.com/old")),
            kind: .imageURL,
            fit: .fill,
            deviceIDs: ["display-one"],
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let recent = SharedLinkRequest(
            instanceID: "home",
            url: try XCTUnwrap(URL(string: "https://example.com/recent")),
            kind: .webpage,
            fit: .fit,
            deviceIDs: ["display-one"],
            createdAt: Date(timeIntervalSince1970: 300),
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        try await store.enqueue(old)
        try await store.enqueue(recent)
        try await store.purge(expiredBefore: Date(timeIntervalSince1970: 200))

        let retained = try await store.requests()
        XCTAssertEqual(retained, [recent])
    }
}
