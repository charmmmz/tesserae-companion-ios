import Foundation
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

@MainActor
final class LineupsAppModelTests: XCTestCase {
    func testLineupDisplayGroupingDistinguishesUnassignedAndUnavailable() {
        let knownDisplayIDs: Set<String> = ["picpak"]

        XCTAssertEqual(
            lineupDisplayGrouping(
                deviceIDs: [],
                knownDisplayIDs: knownDisplayIDs
            ),
            .unassigned
        )
        XCTAssertEqual(
            lineupDisplayGrouping(
                deviceIDs: ["missing"],
                knownDisplayIDs: knownDisplayIDs
            ),
            .unavailable
        )
        XCTAssertEqual(
            lineupDisplayGrouping(
                deviceIDs: ["picpak"],
                knownDisplayIDs: knownDisplayIDs
            ),
            .display("picpak")
        )
    }

    func testLineupDisplayResolutionFallsBackToDashboardBindings() {
        XCTAssertEqual(
            resolvedLineupDeviceIDs(
                explicitDeviceIDs: [],
                dashboardDeviceIDs: [["black-picpak"], ["black-picpak"]]
            ),
            ["black-picpak"]
        )
        XCTAssertEqual(
            resolvedLineupDeviceIDs(
                explicitDeviceIDs: ["explicit-display"],
                dashboardDeviceIDs: [["dashboard-display"]]
            ),
            ["explicit-display"]
        )
    }

    func testHomeDashboardNoticeDescribesReturnBehavior() {
        XCTAssertEqual(
            lineupAdvancedSetupMessage(
                reason: "has a home dashboard",
                homeDashboardName: "Weather",
                homeTimeoutMinutes: 15
            ),
            "Weather is shown first. After 15 minutes of inactivity, this Lineup returns to it. Edit this in Tesserae on the web."
        )
        XCTAssertEqual(
            lineupAdvancedSetupMessage(
                reason: "has a home dashboard",
                homeDashboardName: "Weather",
                homeTimeoutMinutes: 0
            ),
            "Weather is shown first when this Lineup is pushed. Automatic return is off. Edit this in Tesserae on the web."
        )
        XCTAssertEqual(
            lineupAdvancedSetupMessage(
                reason: "has a home dashboard",
                homeDashboardName: nil,
                homeTimeoutMinutes: nil
            ),
            "A home dashboard is configured, but this server does not provide its return timing to the app. View or change it in Tesserae on the web."
        )
    }

    func testLegacyLineupWebURLResolvesToEditor() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://tesserae.example"))

        let resolved = lineupWebURL(
            "/decks/kitchen-deck",
            lineupID: "kitchen-deck",
            relativeTo: baseURL
        )

        XCTAssertEqual(resolved?.absoluteString, "https://tesserae.example/decks/kitchen-deck/edit")
    }

    func testLineupWebURLLeavesNonLegacyRoutesUntouched() throws {
        let baseURL = try XCTUnwrap(URL(string: "https://tesserae.example"))
        let values = [
            "/decks/kitchen-deck/edit",
            "/decks/another-deck",
            "/decks/kitchen-deck?mode=preview",
            "/decks/kitchen-deck#details",
            "https://elsewhere.example/decks/kitchen-deck",
        ]

        for value in values {
            let resolved = lineupWebURL(
                value,
                lineupID: "kitchen-deck",
                relativeTo: baseURL
            )
            let expected = URL(string: value, relativeTo: baseURL)?.absoluteURL

            XCTAssertEqual(resolved, expected, "Unexpectedly rewrote \(value)")
        }
    }

    func testDemoConnectionLoadsCapabilityGatedLineups() async {
        let model = makeAppModel()

        await model.connectDemo()

        XCTAssertTrue(model.supportsLineups)
        XCTAssertTrue(model.supportsLineupControl)
        XCTAssertEqual(model.lineups.map(\.id), ["kitchen-deck"])
    }

    func testForbiddenLineupsKeepTheServerConnectedAndAskForRepairing() async {
        let client = MockTesseraeClient(
            latency: .milliseconds(0),
            lineupFetchError: .forbidden(
                message: "Grant this permission in Tesserae Settings.",
                requestID: nil
            )
        )
        let model = makeAppModel(client: client)

        await model.connectDemo()

        XCTAssertEqual(model.connectionHealth, .connected)
        XCTAssertNotNil(model.activeInstance)
        XCTAssertTrue(model.lineups.isEmpty)
        XCTAssertEqual(
            model.lastError,
            "This pairing does not include Lineups access. Pair again to use Lineups."
        )
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
        XCTAssertEqual(model.lineups.first?.current.first?.pageID, "morning")

        let disabled = await model.setLineupEnabled(lineup, enabled: false)

        XCTAssertTrue(disabled)
        XCTAssertEqual(model.lineups.first?.enabled, false)
        XCTAssertFalse(model.isOperatingOnLineup(lineup.id))
    }

    func testLineupPageCanLoadPreviewWithoutDashboardSummaryLookup() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let lineup = try XCTUnwrap(model.lineups.first)
        let pageID = try XCTUnwrap(lineup.current.first?.pageID)
        let deviceID = try XCTUnwrap(lineup.deviceIDs.first)

        await model.loadDashboardPreview(id: pageID, deviceID: deviceID)

        let preview = model.dashboardPreview(id: pageID, deviceID: deviceID)
        XCTAssertNotNil(preview?.data)
        XCTAssertEqual(
            preview?.eTag,
            "\"dashboard-preview-\(pageID)-\(deviceID)\""
        )
    }

    private func makeAppModel(
        client: MockTesseraeClient = MockTesseraeClient(
            latency: .milliseconds(0)
        )
    ) -> AppModel {
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
