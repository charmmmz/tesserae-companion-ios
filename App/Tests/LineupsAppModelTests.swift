import Foundation
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

@MainActor
final class LineupsAppModelTests: XCTestCase {
    func testDemoConnectionLoadsCapabilityGatedLineups() async {
        let model = makeAppModel()

        await model.connectDemo()

        XCTAssertTrue(model.supportsLineups)
        XCTAssertTrue(model.supportsLineupControl)
        XCTAssertEqual(model.lineups.map(\.id), ["kitchen-deck"])
    }

    func testEnableAndPaintControlsUpdateStateAndActivity() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let lineup = try XCTUnwrap(model.lineups.first)

        let painted = await model.controlLineup(
            lineup,
            action: .next,
            deviceIDs: lineup.deviceIDs
        )

        XCTAssertTrue(painted)
        XCTAssertEqual(model.jobs.first?.kind, .lineupAction)
        XCTAssertEqual(model.jobs.first?.status, .succeeded)

        let disabled = await model.setLineupEnabled(lineup, enabled: false)

        XCTAssertTrue(disabled)
        XCTAssertEqual(model.lineups.first?.enabled, false)
        XCTAssertFalse(model.isOperatingOnLineup(lineup.id))
    }

    private func makeAppModel() -> AppModel {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        return AppModel(
            liveClient: client,
            demoClient: client,
            credentials: InMemoryCredentialStore(),
            stateStore: InMemoryCompanionStateStore(),
            sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: [])
        )
    }
}
