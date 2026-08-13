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

    func testLineupDisplayResolutionUsesServerAuthority() {
        XCTAssertEqual(
            resolvedLineupDeviceIDs(
                explicitDeviceIDs: [],
                serverResolvedDeviceIDs: ["black-picpak", "black-picpak"]
            ),
            ["black-picpak"]
        )
        XCTAssertEqual(
            resolvedLineupDeviceIDs(
                explicitDeviceIDs: ["explicit-display"],
                serverResolvedDeviceIDs: nil
            ),
            ["explicit-display"]
        )
        XCTAssertEqual(
            resolvedLineupDeviceIDs(
                explicitDeviceIDs: [],
                serverResolvedDeviceIDs: nil
            ),
            []
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
        XCTAssertTrue(model.supportsLineupAuthoring)
        XCTAssertTrue(model.supportsSessionRead)
        XCTAssertEqual(model.lineupAuthoringPermission, .granted)
        XCTAssertEqual(
            model.lineupAuthoringSettingsURL,
            "/settings/companion"
        )
        XCTAssertEqual(
            lineupAuthoringWebURL(model: model)?.absoluteString,
            "http://tesserae.local:8765/settings/companion"
        )
        XCTAssertEqual(model.lineups.map(\.id), ["kitchen-deck"])
    }

    func testCreateAndEditLineupUpdatesLocalCollection() async throws {
        let model = makeAppModel()
        await model.connectDemo()

        let created = await model.createLineup(
            LineupCreateRequest(
                intent: .manual,
                name: "Weekend Rotation",
                pageIDs: ["pantry", "photo-frame"],
                deviceIDs: ["picpak-kitchen"]
            )
        )

        let createdLineup: Lineup
        switch created {
        case let .saved(lineup):
            createdLineup = lineup
        default:
            return XCTFail("Expected the Lineup to be created")
        }
        XCTAssertEqual(createdLineup.id, "weekend_rotation")
        XCTAssertEqual(model.lineups.count, 2)

        let versioned = try await model.fetchLineupForEditing(createdLineup.id)
        let updated = await model.updateLineup(
            id: createdLineup.id,
            eTag: versioned.eTag,
            patch: LineupPatchRequest(name: "Weekend")
        )

        switch updated {
        case let .saved(lineup):
            XCTAssertEqual(lineup.name, "Weekend")
            XCTAssertEqual(
                model.lineups.first { $0.id == createdLineup.id }?.name,
                "Weekend"
            )
        default:
            XCTFail("Expected the Lineup to be edited")
        }

        let stale = try await model.fetchLineupForEditing(createdLineup.id)
        _ = await model.setLineupEnabled(stale.lineup, enabled: false)
        let conflict = await model.updateLineup(
            id: stale.lineup.id,
            eTag: stale.eTag,
            patch: LineupPatchRequest(name: "Stale edit")
        )
        guard case .conflict = conflict else {
            return XCTFail("Expected a concurrent edit conflict")
        }
    }

    func testMissingWriteScopeKeepsPairingAndReturnsPermissionRemedy() async {
        let client = MockTesseraeClient(
            latency: .milliseconds(0),
            lineupAuthoringGranted: false
        )
        let model = makeAppModel(client: client)
        await model.connectDemo()

        let outcome = await model.createLineup(
            LineupCreateRequest(
                intent: .daily,
                name: "Weather",
                pageIDs: ["pantry"],
                deviceIDs: []
            )
        )

        guard case .permissionRequired = outcome else {
            return XCTFail("Expected a permission remedy")
        }
        XCTAssertEqual(model.lineupAuthoringPermission, .denied)
        XCTAssertEqual(model.connectionHealth, .connected)
        XCTAssertNotNil(model.activeInstance)
    }

    func testLineupEditorDraftValidatesIntentAndBuildsPartialPatch() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let lineup = try XCTUnwrap(model.lineups.first)

        var daily = LineupEditorDraft(intent: .daily)
        daily.name = "Weather"
        daily.pageIDs = ["pantry", "morning"]
        XCTAssertFalse(daily.isValid)
        daily.pageIDs = ["pantry"]
        daily.firesAtMinutes = 7 * 60 + 5
        XCTAssertTrue(daily.isValid)
        XCTAssertEqual(daily.createRequest.firesAt, "07:05")

        var interval = LineupEditorDraft(intent: .interval)
        interval.name = "Keep Weather Fresh"
        interval.pageIDs = ["pantry"]
        interval.intervalMinutes = 45
        interval.anchorMinutes = 6 * 60
        XCTAssertEqual(interval.createRequest.intervalMinutes, 45)
        XCTAssertEqual(interval.createRequest.anchor, "06:00")

        var cycle = LineupEditorDraft(intent: .cycle)
        cycle.name = "Morning Cycle"
        cycle.pageIDs = ["pantry", "morning"]
        XCTAssertFalse(cycle.isValid)
        cycle.deviceIDs = ["picpak-kitchen"]
        cycle.dwellMinutes = ["pantry": 15, "morning": 30]
        cycle.anchorMinutes = 5 * 60 + 30
        XCTAssertTrue(cycle.isValid)
        XCTAssertEqual(
            cycle.createRequest.dwellMinutes,
            ["pantry": 15, "morning": 30]
        )
        XCTAssertEqual(cycle.createRequest.anchor, "05:30")

        var edit = LineupEditorDraft(lineup: lineup)
        edit.name = "Renamed"
        let patch = edit.patch(comparedTo: lineup)
        XCTAssertEqual(patch.name, "Renamed")
        XCTAssertNil(patch.deviceIDs)
        XCTAssertNil(patch.pageIDs)
        XCTAssertNil(patch.dwellMinutes)
        XCTAssertNil(patch.intervalMinutes)
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
