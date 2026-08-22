import Foundation
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

@MainActor
final class ActivityJobExpiryTests: XCTestCase {
    func testExpiredTrackedJobIsRemovedWithoutErrorBanner() async throws {
        let instance = TesseraeInstance(
            id: "instance-1",
            name: "Tesserae",
            baseURL: try XCTUnwrap(URL(string: "http://tesserae.local:8765")),
            serverVersion: "0.317.0",
            timezone: "Asia/Shanghai",
            webURL: "http://tesserae.local:8765/"
        )
        let credentials = InMemoryCredentialStore()
        await credentials.save(token: "companion-secret", for: instance.id)

        let staleJob = PushJob(
            id: "job_stale",
            kind: .imagePush,
            status: .running,
            label: "Shared photo",
            targetDeviceIDs: ["picpak-4fe844"],
            createdAt: Date(timeIntervalSinceNow: -86_400 * 2),
            updatedAt: Date(timeIntervalSinceNow: -86_400 * 2)
        )
        let stateStore = InMemoryCompanionStateStore(
            snapshot: CompanionSnapshot(
                activeInstance: instance,
                capabilities: nil,
                displays: [],
                dashboards: [],
                lineups: [],
                jobs: [staleJob],
                updatedAt: Date()
            )
        )

        let client = MockTesseraeClient(
            latency: .milliseconds(0),
            jobFetchError: TesseraeClientError.server(
                code: "not_found",
                message: "No job with that id.",
                requestID: "req_test"
            )
        )
        let model = AppModel(
            liveClient: client,
            demoClient: client,
            credentials: credentials,
            stateStore: stateStore,
            sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: [])
        )

        await model.restoreConnectionIfNeeded()
        await model.synchronizeSharedActivity()

        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNil(model.lastError)
    }
}
