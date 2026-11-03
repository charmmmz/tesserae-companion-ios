import Foundation
import TesseraeKit
import XCTest
import Testing
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
        XCTAssertTrue(model.hasReadCurrentLineups)
        XCTAssertNil(model.lineupsReadError)
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
        XCTAssertFalse(model.hasReadCurrentLineups)
        XCTAssertNotNil(model.lineupsReadError)
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

    func testScheduleNavigationRetainsMissingTargetCoverage() {
        XCTAssertEqual(LineupNavigationState(targetIDs: [], current: []), .noTargets)
        XCTAssertEqual(LineupNavigationState(targetIDs: ["a", "b"], current: []), .noReports(missing: 2))
        let report = LineupCurrent(deviceID: "a", pageID: "weather")
        XCTAssertEqual(LineupNavigationState(targetIDs: ["a", "b"], current: [report]), .samePage(id: "weather", missing: 1))
        XCTAssertEqual(LineupNavigationState(targetIDs: ["a", "b", "missing"], current: [report, .init(deviceID: "b", pageID: "news")]), .mixedPages(missing: 1))
    }

    func testStepNavigationOnlySuppressesSendWhenEverySelectedTargetMatches() {
        let current = [LineupCurrent(deviceID: "a", pageID: "weather"), LineupCurrent(deviceID: "b", pageID: "news")]
        let partial = LineupStepNavigation(pageID: "weather", targetIDs: ["a", "b"], current: current)
        XCTAssertEqual(partial.matchingTargetIDs, ["a"])
        XCTAssertFalse(partial.allSelectedTargetsMatch)
        XCTAssertTrue(LineupStepNavigation(pageID: "weather", targetIDs: ["a"], current: current).allSelectedTargetsMatch)
        XCTAssertFalse(LineupStepNavigation(pageID: "weather", targetIDs: [], current: current).allSelectedTargetsMatch)
    }

    func testPlannedUpdatesRequireExactDisplayLineupAndDashboardEvidence() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let display = try XCTUnwrap(model.displays.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let valid = DeviceUpcomingEvent(id: "right", scheduledAt: now.addingTimeInterval(60), cause: .cycle, effect: .changeScreen, certainty: .conditional, lineupID: "lineup", dashboardID: "page")
        let other = DeviceUpcomingEvent(id: "wrong", scheduledAt: now.addingTimeInterval(30), cause: .daily, effect: .changeScreen, certainty: .scheduled, lineupID: "other", dashboardID: "page")
        let beforeProjection = DeviceUpcomingEvent(id: "before", scheduledAt: now.addingTimeInterval(-30), cause: .daily, effect: .changeScreen, certainty: .scheduled, lineupID: "lineup", dashboardID: "page")
        let afterHorizon = DeviceUpcomingEvent(id: "after", scheduledAt: now.addingTimeInterval(3601), cause: .daily, effect: .changeScreen, certainty: .scheduled, lineupID: "lineup", dashboardID: "page")
        let response = DeviceUpcomingResponse(deviceID: display.id, generatedAt: now, timezone: "Asia/Shanghai", throughAt: now.addingTimeInterval(3600), events: [other, valid, beforeProjection, afterHorizon])
        let plans = displayPlanProjections(deviceIDs: [display.id, "missing"], displays: model.displays, supported: true, responses: [display.id: response], refreshing: [], errors: [:], lineupID: "lineup", now: now)
        XCTAssertEqual(plans.count, 2)
        XCTAssertEqual(plans[0].next?.event, valid)
        XCTAssertEqual(plans[0].events.map(\.event.id), ["right"])
        XCTAssertEqual(plans[0].next?.displayID, display.id)
        XCTAssertEqual(plans[0].next?.generatedAt, now)
        XCTAssertEqual(plans[1].availability, .unavailable)
        let mismatched = DeviceUpcomingResponse(deviceID: "another-display", generatedAt: now, timezone: "UTC", throughAt: now.addingTimeInterval(3600), events: [valid])
        let rejected = displayPlanProjections(deviceIDs: [display.id], displays: model.displays, supported: true, responses: [display.id: mismatched], refreshing: [], errors: [:], lineupID: "lineup", now: now)
        XCTAssertNil(rejected[0].next)
        XCTAssertNil(rejected[0].response)
        let noMatch = displayPlanProjections(deviceIDs: [display.id], displays: model.displays, supported: true, responses: [display.id: response], refreshing: [], errors: [:], lineupID: "absent", now: now)
        XCTAssertEqual(noMatch[0].availability, .available)
        XCTAssertTrue(noMatch[0].events.isEmpty)
    }

    func testCachedPlanKeepsErrorAndExpiryNeverPromisesFutureUpdates() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let display = try XCTUnwrap(model.displays.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let event = DeviceUpcomingEvent(id: "cached", scheduledAt: now.addingTimeInterval(60), cause: .interval, effect: .refreshScreen, certainty: .estimated)
        let response = DeviceUpcomingResponse(deviceID: display.id, generatedAt: now.addingTimeInterval(-60), timezone: "UTC", throughAt: now.addingTimeInterval(120), events: [event])
        func project(at date: Date, supported: Bool = true) -> DisplayPlanProjection {
            displayPlanProjections(deviceIDs: [display.id], displays: model.displays, supported: supported, responses: [display.id: response], refreshing: [display.id], errors: [display.id: "Refresh failed"], now: date)[0]
        }
        XCTAssertEqual(project(at: now).error, "Refresh failed")
        XCTAssertEqual(project(at: now).next?.event, event)
        XCTAssertTrue(project(at: now).isRefreshing)
        XCTAssertNil(project(at: now.addingTimeInterval(70)).next)
        XCTAssertEqual(project(at: now.addingTimeInterval(121)).availability, .expired)
        XCTAssertNil(project(at: now.addingTimeInterval(121)).next)
        XCTAssertEqual(project(at: now, supported: false).availability, .unsupported)
        XCTAssertNil(project(at: now, supported: false).next)
    }

    func testPlannedTimeUsesProjectionTimezoneAcrossMidnight() {
        let utc = ISO8601DateFormatter().date(from: "2026-11-02T23:30:00Z")!
        let event = DeviceUpcomingEvent(id: "timezone", scheduledAt: utc, cause: .daily, effect: .changeScreen, certainty: .scheduled)
        let context = PlannedDisplayEvent(displayID: "a", displayName: "A", event: event, generatedAt: utc, throughAt: utc.addingTimeInterval(3600), timezone: "Asia/Shanghai")
        let formatted = plannedEventTime(context)
        XCTAssertTrue(formatted.contains("07:30") || formatted.contains("7:30"), formatted)
        XCTAssertFalse(formatted.contains("23:30"), formatted)
    }

    func testScheduleTimeWindowUsesServerDayAndExactBoundaries() throws {
        let lineup = try scheduleFixture(["intent": "cycle", "anchor": "09:00", "endAt": "11:00", "daysOfWeek": [0]])
        let now = ISO8601DateFormatter().date(from: "2026-11-02T02:00:00Z")!
        let window = try XCTUnwrap(ScheduleTimeWindow.active(for: lineup, timezoneID: "Asia/Shanghai", now: now))
        XCTAssertEqual(window.fractionElapsed(at: now), 0.5, accuracy: 0.0001)
        XCTAssertEqual(window.fractionElapsed(at: window.start.addingTimeInterval(-60)), 0)
        XCTAssertEqual(window.fractionElapsed(at: window.end.addingTimeInterval(60)), 1)
        XCTAssertNotNil(ScheduleTimeWindow.active(for: lineup, timezoneID: "Asia/Shanghai", now: window.start))
        XCTAssertNil(ScheduleTimeWindow.active(for: lineup, timezoneID: "Asia/Shanghai", now: window.end))
        XCTAssertNil(ScheduleTimeWindow.active(for: lineup, timezoneID: "UTC", now: now))
        XCTAssertNil(ScheduleTimeWindow.active(for: lineup, timezoneID: "Invalid/Zone", now: now))
        XCTAssertNil(ScheduleTimeWindow.active(for: lineup, timezoneID: nil, now: now))
        let serverMonday = try scheduleFixture(["intent": "interval", "windowStart": "00:00", "windowEnd": "02:00", "endAt": NSNull(), "daysOfWeek": [0]])
        let sundayUTC = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
        XCTAssertNotNil(ScheduleTimeWindow.active(for: serverMonday, timezoneID: "Asia/Shanghai", now: sundayUTC))
    }

    func testScheduleTimeWindowRejectsAmbiguousAndIncompleteMetadata() throws {
        let now = ISO8601DateFormatter().date(from: "2026-11-02T02:00:00Z")!
        let invalid: [[String: Any]] = [
            ["enabled": false], ["daysOfWeek": NSNull()], ["daysOfWeek": []], ["daysOfWeek": [7]],
            ["intent": "manual"], ["intent": "daily"], ["intent": NSNull()],
            ["anchor": "11:00", "endAt": "09:00"], ["anchor": "09:00", "endAt": "09:00"],
            ["anchor": "9:00"], ["anchor": "25:00"], ["endAt": NSNull()],
            ["windowStart": "09:00"], ["windowStart": "08:00", "windowEnd": "11:00"],
            ["intent": "interval", "windowStart": "09:00"],
            ["intent": "interval", "windowStart": "09:00", "windowEnd": "11:00", "endAt": "12:00"]
        ]
        for patch in invalid {
            let lineup = try scheduleFixture(patch)
            XCTAssertNil(ScheduleTimeWindow.active(for: lineup, timezoneID: "Asia/Shanghai", now: now), "\(patch)")
        }
        let interval = try scheduleFixture(["intent": "interval", "anchor": "06:00", "windowStart": "09:00", "windowEnd": "11:00", "endAt": NSNull()])
        XCTAssertNotNil(ScheduleTimeWindow.active(for: interval, timezoneID: "Asia/Shanghai", now: now))
        let matching = try scheduleFixture(["windowStart": "09:00", "windowEnd": "11:00"])
        XCTAssertNotNil(ScheduleTimeWindow.active(for: matching, timezoneID: "Asia/Shanghai", now: now))
    }

    func testScheduleTimeWindowSuppressesMissingAndRepeatedDSTBounds() throws {
        let fall = try scheduleFixture(["anchor": "01:30", "endAt": "03:00"])
        let fallNow = ISO8601DateFormatter().date(from: "2026-11-01T07:00:00Z")!
        XCTAssertNil(ScheduleTimeWindow.active(for: fall, timezoneID: "America/New_York", now: fallNow))
        let spring = try scheduleFixture(["anchor": "02:30", "endAt": "04:00"])
        let springNow = ISO8601DateFormatter().date(from: "2026-03-08T07:30:00Z")!
        XCTAssertNil(ScheduleTimeWindow.active(for: spring, timezoneID: "America/New_York", now: springNow))
        let acrossFall = try scheduleFixture(["anchor": "00:00", "endAt": "03:00"])
        XCTAssertNil(ScheduleTimeWindow.active(for: acrossFall, timezoneID: "America/New_York", now: fallNow))
        let acrossSpring = try scheduleFixture(["anchor": "00:00", "endAt": "04:00"])
        XCTAssertNil(ScheduleTimeWindow.active(for: acrossSpring, timezoneID: "America/New_York", now: springNow))
        let valid = try scheduleFixture(["anchor": "03:00", "endAt": "05:00"])
        XCTAssertNotNil(ScheduleTimeWindow.active(for: valid, timezoneID: "America/New_York", now: springNow))
    }

    func testSubsequentPlanEventsAreActualFutureEventsAndDisappearOnExpiry() async throws {
        let model = makeAppModel()
        await model.connectDemo()
        let display = try XCTUnwrap(model.displays.first)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [-10, 20, 40, 60].map { offset in
            DeviceUpcomingEvent(id: "event-\(offset)", scheduledAt: now.addingTimeInterval(Double(offset)), cause: .cycle, effect: .changeScreen, certainty: .estimated, lineupID: "explicit-\(offset)")
        }
        let response = DeviceUpcomingResponse(deviceID: display.id, generatedAt: now.addingTimeInterval(-60), timezone: "UTC", throughAt: now.addingTimeInterval(120), events: events.reversed())
        func plan(at date: Date) -> DisplayPlanProjection {
            displayPlanProjections(deviceIDs: [display.id], displays: model.displays, supported: true, responses: [display.id: response], refreshing: [], errors: [:], now: date)[0]
        }
        XCTAssertEqual(plan(at: now).next?.event.id, "event-20")
        XCTAssertEqual(plan(at: now).subsequentEvents.map(\.event.id), ["event-40", "event-60"])
        XCTAssertEqual(plan(at: now.addingTimeInterval(30)).next?.event.lineupID, "explicit-40")
        XCTAssertEqual(plan(at: now.addingTimeInterval(30)).subsequentEvents.map(\.event.id), ["event-60"])
        XCTAssertTrue(plan(at: now.addingTimeInterval(121)).futureEvents.isEmpty)
    }

    func testCompactProjectionDatesKeepNonTodayDateInServerTimezone() {
        let now = ISO8601DateFormatter().date(from: "2026-11-02T17:00:00Z")!
        let sameServerDay = ISO8601DateFormatter().date(from: "2026-11-02T16:30:00Z")!
        let previousServerDay = ISO8601DateFormatter().date(from: "2026-11-02T15:30:00Z")!
        let same = compactProjectionDateText(sameServerDay, timezone: "Asia/Shanghai", now: now)
        let previous = compactProjectionDateText(previousServerDay, timezone: "Asia/Shanghai", now: now)
        XCTAssertTrue(same.contains("00:30") || same.contains("0:30"), same)
        XCTAssertTrue(previous.contains("2"), previous)
        XCTAssertGreaterThan(previous.count, same.count)
        let first = ISO8601DateFormatter().date(from: "2026-11-01T05:30:00Z")!
        let second = first.addingTimeInterval(3600)
        XCTAssertFalse(same.contains("GMT"), same)
        XCTAssertFalse(previous.contains("GMT"), previous)
        XCTAssertEqual(compactProjectionDateText(first, timezone: "America/New_York", now: first),
                       compactProjectionDateText(second, timezone: "America/New_York", now: first))
        let firstText = projectionDateText(first, timezone: "America/New_York")
        let secondText = projectionDateText(second, timezone: "America/New_York")
        XCTAssertTrue(firstText.contains(":30"), firstText)
        XCTAssertTrue(secondText.contains(":30"), secondText)
        XCTAssertNotEqual(firstText, secondText)
    }

    func testTimezoneNoticeComparesOffsetsForAllDisplayedDates() throws {
        let winter = ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z")!
        let summer = ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z")!
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let alias = try XCTUnwrap(TimeZone(identifier: "Asia/Chongqing"))
        let london = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(serverTimezoneDiffers(shanghai, at: [winter, summer], phoneTimezone: alias))
        XCTAssertTrue(serverTimezoneDiffers(shanghai, at: [winter], phoneTimezone: utc))
        XCTAssertFalse(serverTimezoneDiffers(london, at: [winter], phoneTimezone: utc))
        XCTAssertTrue(serverTimezoneDiffers(london, at: [winter, summer], phoneTimezone: utc))
        XCTAssertFalse(serverTimezoneDiffers(london, at: [], phoneTimezone: utc))
        XCTAssertEqual(effectiveServerTimezone(nil, fallbackID: "Asia/Shanghai"), shanghai)
        XCTAssertEqual(effectiveServerTimezone("invalid", fallbackID: "Asia/Shanghai"), shanghai)
        XCTAssertEqual(effectiveServerTimezone("Europe/London", fallbackID: "Asia/Shanghai"), london)
        XCTAssertEqual(effectiveServerTimezone("invalid", fallbackID: "also-invalid"), utc)
    }

    private func scheduleFixture(_ patch: [String: Any]) throws -> Lineup {
        var values: [String: Any] = [
            "id": "schedule", "name": "Schedule", "enabled": true, "intent": "cycle",
            "deviceIds": [], "dashboards": [], "current": [], "advance": "timer",
            "anchor": "09:00", "endAt": "11:00", "daysOfWeek": Array(0...6),
            "nativeEditable": true, "webUrl": "/decks/schedule"
        ]
        values.merge(patch) { _, replacement in replacement }
        return try JSONDecoder().decode(Lineup.self, from: JSONSerialization.data(withJSONObject: values))
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


@Suite("Lineup target editing")
@MainActor
struct LineupTargetEditingTests {
    @Test("Scheduled Lineups accept inherited or explicit targets", arguments: [LineupIntent.daily, .interval], [[], ["e1004-desk", "picpak-kitchen"]])
    func createTargets(intent: LineupIntent, targets: [String]) throws {
        var draft = LineupEditorDraft(intent: intent)
        draft.name = "Weather"
        draft.pageIDs = ["pantry"]
        draft.deviceIDs = targets
        #expect(draft.isValid)
        #expect(!draft.requiresDisplaySelection)
        #expect(!draft.createRequest.bindUnassignedDashboards)
        let body = try #require(JSONSerialization.jsonObject(
            with: TesseraeJSON.encoder().encode(draft.createRequest)
        ) as? [String: Any])
        #expect((body["device_ids"] as? [String] ?? []) == targets)
        #expect(body["page_ids"] as? [String] == ["pantry"])
    }

    @Test("Scheduled target overrides can be preserved, replaced, and explicitly cleared", arguments: [LineupIntent.daily, .interval])
    func editTargets(intent: LineupIntent) async throws {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        let instance = TesseraeInstance(
            id: "test", name: "Test", baseURL: try #require(URL(string: "https://tesserae.example")),
            serverVersion: "0.441.5", timezone: "UTC", webURL: "/"
        )
        let original = try await client.createLineup(
            .init(intent: intent, name: "Weather", pageIDs: ["pantry"], deviceIDs: ["e1004-desk", "picpak-kitchen"]),
            instance: instance
        ).lineup
        var draft = LineupEditorDraft(lineup: original)
        #expect(draft.deviceIDs == ["e1004-desk", "picpak-kitchen"])
        draft.name = "Weather renamed"
        #expect(draft.patch(comparedTo: original).deviceIDs == nil)
        draft.deviceIDs.reverse()
        #expect(draft.patch(comparedTo: original).deviceIDs == nil)
        draft.deviceIDs = ["e1004-desk"]
        #expect(draft.patch(comparedTo: original).deviceIDs == ["e1004-desk"])
        #expect(draft.pageIDs == ["pantry"])
        draft.deviceIDs = []
        let patch = draft.patch(comparedTo: original)
        let body = try #require(JSONSerialization.jsonObject(
            with: TesseraeJSON.encoder().encode(patch)
        ) as? [String: Any])
        #expect(body["device_ids"] as? [String] == [])
        #expect(body["page_ids"] == nil)
        #expect(draft.isValid)
    }

    @Test("Cycle and Manual still require a display", arguments: [LineupIntent.cycle, .manual])
    func requiredTargets(intent: LineupIntent) {
        var draft = LineupEditorDraft(intent: intent)
        draft.name = "Rotation"
        draft.pageIDs = ["pantry", "morning"]
        #expect(!draft.isValid)
        #expect(draft.requiresDisplaySelection)
        draft.deviceIDs = ["picpak-kitchen"]
        #expect(draft.isValid)
    }
}


@Suite("Dashboard web links")
struct DashboardWebLinkTests {
    @Test(arguments: [
        ("/pages/pantry", "https://tesserae.example/pages/pantry"),
        ("pages/pantry?edit=1#layout", "https://tesserae.example/server/pages/pantry?edit=1#layout"),
        ("https://other.example/editor/123", "https://other.example/editor/123"),
        (" /pages/pantry ", "https://tesserae.example/pages/pantry")
    ])
    func resolvesProvidedURL(path: String, expected: String) throws {
        let base = try #require(URL(string: "https://tesserae.example/server/"))
        #expect(dashboardWebURL(path, relativeTo: base)?.absoluteString == expected)
    }

    @Test(arguments: [nil, "", "  ", "javascript:alert(1)", "file:///tmp/page", "mailto:user@example.com"] as [String?])
    func missingOrNonWebURLIsHidden(path: String?) throws {
        let base = try #require(URL(string: "https://tesserae.example"))
        #expect(dashboardWebURL(path, relativeTo: base) == nil)
    }
}
