import Foundation
import TesseraeKit
import Testing
@testable import Tesserae_Companion

@Suite("Lineup unsaved changes")
@MainActor
struct LineupEditingStateTests {
    @Test("Clean exits are immediate, dirty exits require a decision, and saving blocks both", arguments: [
        LineupEditingSession.ExitDestination.back, .close,
    ])
    func exitDecision(destination: LineupEditingSession.ExitDestination) {
        let session = LineupEditingSession()
        #expect(session.canExit(to: destination))
        #expect(session.pendingExit == nil)
        session.hasChanges = true
        #expect(!session.canExit(to: destination))
        #expect(session.pendingExit == destination)
        session.pendingExit = nil
        session.isSaving = true
        #expect(!session.canExit(to: destination))
        #expect(session.pendingExit == nil)
        session.hasChanges = false
        #expect(!session.canExit(to: destination))
        session.isSaving = false
        #expect(session.canExit(to: destination))
    }

    @Test("Unchanged drafts are clean", arguments: [LineupIntent.daily, .interval, .cycle, .manual])
    func unchangedDraft(intent: LineupIntent) {
        let draft = populatedDraft(intent: intent)
        #expect(!draft.hasChanges(comparedTo: draft))
    }

    @Test("Whitespace and device ordering do not change the saved meaning")
    func cosmeticChangesAreClean() {
        let original = populatedDraft(intent: .cycle)
        var draft = original
        draft.name = " \nWeekend\t "
        draft.deviceIDs = ["desk", "kitchen", "desk"]
        #expect(!draft.hasChanges(comparedTo: original))

        draft.name = "Weekday"
        #expect(draft.hasChanges(comparedTo: original))
        draft.name = original.name
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Changing and restoring selected devices restores the clean state")
    func changedBackDevicesAreClean() {
        let original = populatedDraft(intent: .cycle)
        var draft = original
        draft.deviceIDs = ["kitchen"]
        #expect(draft.hasChanges(comparedTo: original))
        draft.deviceIDs = original.deviceIDs
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Dashboard order is meaningful", arguments: [LineupIntent.cycle, .manual])
    func dashboardOrdering(intent: LineupIntent) {
        let original = populatedDraft(intent: intent)
        var draft = original
        draft.pageIDs.reverse()
        #expect(draft.hasChanges(comparedTo: original))
        draft.pageIDs.reverse()
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Unselected dwell values and automatic binding do not make a draft dirty")
    func derivedAndUnselectedValuesAreIgnored() {
        let original = populatedDraft(intent: .cycle)
        var draft = original
        draft.dwellMinutes["removed-dashboard"] = 720
        draft.bindUnassignedDashboards = true
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Only Daily uses its time of day", arguments: [
        (LineupIntent.daily, true), (.interval, false), (.cycle, false), (.manual, false),
    ])
    func dailyTimeChange(intent: LineupIntent, isMeaningful: Bool) {
        let original = populatedDraft(intent: intent)
        var draft = original
        draft.firesAtMinutes = 8 * 60 + 15
        #expect(draft.hasChanges(comparedTo: original) == isMeaningful)
    }

    @Test("An overridden Cycle duration is unaffected by the default interval", arguments: [
        (LineupIntent.daily, false), (.interval, true), (.cycle, false), (.manual, false),
    ])
    func intervalChange(intent: LineupIntent, isMeaningful: Bool) {
        let original = populatedDraft(intent: intent)
        var draft = original
        draft.intervalMinutes = 45
        #expect(draft.hasChanges(comparedTo: original) == isMeaningful)
    }

    @Test("A Cycle without a Dashboard override uses its default duration")
    func inheritedCycleDurationChange() {
        var original = populatedDraft(intent: .cycle)
        original.dwellMinutes["calendar"] = nil
        var draft = original
        draft.intervalMinutes = 45
        #expect(draft.hasChanges(comparedTo: original))
        draft.intervalMinutes = original.intervalMinutes
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Only Cycle uses the daily start time", arguments: [
        (LineupIntent.daily, false), (.interval, false), (.cycle, true), (.manual, false),
    ])
    func anchorChange(intent: LineupIntent, isMeaningful: Bool) {
        let original = populatedDraft(intent: intent)
        var draft = original
        draft.anchorMinutes = 6 * 60 + 30
        #expect(draft.hasChanges(comparedTo: original) == isMeaningful)
        draft.anchorMinutes = original.anchorMinutes
        #expect(!draft.hasChanges(comparedTo: original))
    }

    @Test("Only Cycle uses each Dashboard's dwell time", arguments: [
        (LineupIntent.daily, false), (.interval, false), (.cycle, true), (.manual, false),
    ])
    func dwellChange(intent: LineupIntent, isMeaningful: Bool) {
        let original = populatedDraft(intent: intent)
        var draft = original
        draft.dwellMinutes["weather"] = 90
        #expect(draft.hasChanges(comparedTo: original) == isMeaningful)
    }

    @Test("A Cycle start-time edit sends only anchor")
    func anchorOnlyPatch() throws {
        let lineup = try lineupFixture(intent: .cycle, intervalMinutes: 10_080)
        var draft = LineupEditorDraft(lineup: lineup)
        #expect(draft.patch(comparedTo: lineup).isEmpty)
        draft.anchorMinutes = 6 * 60 + 15

        let patch = draft.patch(comparedTo: lineup)
        let body = try #require(JSONSerialization.jsonObject(
            with: TesseraeJSON.encoder().encode(patch)
        ) as? [String: Any])
        #expect(Set(body.keys) == ["anchor"])
        #expect(body["anchor"] as? String == "06:15")

        draft.anchorMinutes = 5 * 60 + 30
        #expect(draft.patch(comparedTo: lineup).isEmpty)
    }

    @Test("Existing long intervals and dwell values survive unchanged", arguments: [LineupIntent.interval, .cycle])
    func longExistingDurationsArePreserved(intent: LineupIntent) throws {
        let lineup = try lineupFixture(intent: intent, intervalMinutes: 10_080)
        let draft = LineupEditorDraft(lineup: lineup)
        #expect(draft.intervalMinutes == 10_080)
        #expect(draft.dwellMinutes["weather"] == 2_885)
        #expect(draft.anchorMinutes == 330)
        #expect(draft.patch(comparedTo: lineup).isEmpty)
        #expect(!draft.hasChanges(comparedTo: LineupEditorDraft(lineup: lineup)))
    }

    @Test("Existing single-Dashboard cycles and manual Lineups remain editable", arguments: [LineupIntent.cycle, .manual])
    func existingSingleDashboardIsEditable(intent: LineupIntent) throws {
        let lineup = try lineupFixture(intent: intent, pageIDs: ["weather"])
        var draft = LineupEditorDraft(lineup: lineup)
        #expect(draft.isValid)
        #expect(draft.validationMessage == nil)
        #expect(draft.patch(comparedTo: lineup).isEmpty)

        draft.name = "Renamed"
        #expect(draft.isValid)
        #expect(draft.patch(comparedTo: lineup).name == "Renamed")
        #expect(draft.patch(comparedTo: lineup).pageIDs == nil)
    }

    @Test("New multi-Dashboard Lineups still require two Dashboards", arguments: [LineupIntent.cycle, .manual])
    func newLineupsStillRequireTwoDashboards(intent: LineupIntent) {
        var draft = populatedDraft(intent: intent)
        draft.pageIDs = ["weather"]
        #expect(!draft.isValid)
        draft.pageIDs.append("calendar")
        #expect(draft.isValid)
    }

    private func populatedDraft(intent: LineupIntent) -> LineupEditorDraft {
        var draft = LineupEditorDraft(intent: intent)
        draft.name = "Weekend"
        draft.deviceIDs = ["kitchen", "desk"]
        draft.pageIDs = draft.takesSingleDashboard ? ["weather"] : ["weather", "calendar"]
        draft.dwellMinutes = ["weather": 15, "calendar": 30]
        return draft
    }

    private func lineupFixture(
        intent: LineupIntent,
        intervalMinutes: Int = 30,
        pageIDs: [String]? = nil
    ) throws -> Lineup {
        let pages = pageIDs ?? (intent == .interval ? ["weather"] : ["weather", "calendar"])
        let body: [String: Any] = [
            "id": "weekend",
            "name": "Weekend",
            "enabled": true,
            "intent": intent.rawValue,
            "device_ids": ["kitchen"],
            "dashboards": pages.map { pageID in
                [
                    "page_id": pageID,
                    "name": pageID,
                    "dwell_minutes": pageID == "weather" ? 2_885 : 4_320,
                    "missing": false,
                ] as [String: Any]
            },
            "current": [],
            "advance": intent == .manual ? "manual" : "timer",
            "interval_minutes": intervalMinutes,
            "anchor": "05:30",
            "native_editable": true,
            "web_url": "/decks/weekend/edit",
        ]
        return try TesseraeJSON.decoder().decode(
            Lineup.self,
            from: JSONSerialization.data(withJSONObject: body)
        )
    }
}

@Suite("Lineup wall-clock time")
@MainActor
struct LineupEditorClockTests {
    @Test("Picker dates preserve HH:mm without a local-time conversion", arguments: [
        (0, 0, 0), (1, 0, 1), (125, 2, 5), (330, 5, 30),
        (450, 7, 30), (720, 12, 0), (1_439, 23, 59),
    ])
    func clockTimeRoundTrip(minutes: Int, hour: Int, minute: Int) throws {
        let date = LineupEditorClock.date(for: minutes)
        var referenceCalendar = Calendar(identifier: .gregorian)
        referenceCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let components = referenceCalendar.dateComponents([.hour, .minute], from: date)

        #expect(components.hour == hour)
        #expect(components.minute == minute)
        #expect(LineupEditorClock.minutes(from: date) == minutes)
        #expect(LineupEditorClock.calendar.identifier == .gregorian)
        #expect(LineupEditorClock.calendar.timeZone.secondsFromGMT(for: date) == 0)
    }

    @Test("Reading a clock value does not inherit daylight-saving transitions", arguments: [
        ("2026-03-08T02:30:00Z", 150),
        ("2026-03-29T02:30:00Z", 150),
        ("2026-10-25T01:30:00Z", 90),
        ("2026-11-01T01:30:00Z", 90),
    ])
    func daylightSavingDatesRemainWallClock(isoDate: String, minutes: Int) throws {
        let date = try #require(ISO8601DateFormatter().date(from: isoDate))
        #expect(LineupEditorClock.minutes(from: date) == minutes)
    }
}
