import Foundation
import XCTest
@testable import TesseraeKit

final class CompanionStateStoreTests: XCTestCase {
    func testRoundTripsSnapshotInSharedDefaults() async throws {
        let suiteName = "TesseraeKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = UserDefaultsCompanionStateStore(suiteName: suiteName)
        let activityClearedBefore = Date(
            timeIntervalSince1970: 1_722_160_700
        )
        let snapshot = CompanionSnapshot(
            activeInstance: fixtureInstance,
            capabilities: nil,
            displays: [],
            dashboards: [],
            jobs: [],
            activityClearedBefore: activityClearedBefore,
            updatedAt: Date(timeIntervalSince1970: 1_722_160_800)
        )

        try await store.save(snapshot)
        let restored = try await store.load()

        XCTAssertEqual(restored, snapshot)
        XCTAssertEqual(restored?.activityClearedBefore, activityClearedBefore)

        try await store.clear()
        let cleared = try await store.load()
        XCTAssertNil(cleared)
    }

    func testRejectsUnsupportedSnapshotSchema() async throws {
        let suiteName = "TesseraeKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let snapshot = CompanionSnapshot(
            schemaVersion: CompanionSnapshot.currentSchemaVersion + 1,
            activeInstance: fixtureInstance,
            capabilities: nil,
            displays: [],
            dashboards: [],
            jobs: []
        )
        defaults.set(
            try TesseraeJSON.encoder().encode(snapshot),
            forKey: "TesseraeCompanionSnapshot"
        )
        let store = UserDefaultsCompanionStateStore(suiteName: suiteName)

        do {
            _ = try await store.load()
            XCTFail("Expected unsupportedSchema")
        } catch {
            XCTAssertEqual(
                error as? CompanionStateStoreError,
                .unsupportedSchema(CompanionSnapshot.currentSchemaVersion + 1)
            )
        }
    }

    private var fixtureInstance: TesseraeInstance {
        TesseraeInstance(
            id: "instance-home",
            name: "Home",
            baseURL: URL(string: "http://tesserae.local:8765")!,
            serverVersion: "0.203.3",
            timezone: "Asia/Shanghai",
            webURL: "http://tesserae.local:8765"
        )
    }

    func testMergesExtensionJobsWithoutRegressingNewerState() {
        let older = PushJob.fixture(
            id: "job-shared",
            status: .accepted,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        let newer = PushJob.fixture(
            id: "job-shared",
            status: .succeeded,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        let extensionJob = PushJob.fixture(
            id: "job-extension",
            status: .accepted,
            updatedAt: Date(timeIntervalSince1970: 300)
        )

        let merged = CompanionSnapshot.mergingJobs(
            current: [newer],
            incoming: [older, extensionJob]
        )

        XCTAssertEqual(merged.map(\.id), ["job-extension", "job-shared"])
        XCTAssertEqual(
            merged.first(where: { $0.id == "job-shared" })?.status,
            .succeeded
        )
    }
}

private extension PushJob {
    static func fixture(
        id: String,
        status: PushJobStatus,
        updatedAt: Date
    ) -> PushJob {
        PushJob(
            id: id,
            kind: .imagePush,
            status: status,
            targetDeviceIDs: ["display"],
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }
}
