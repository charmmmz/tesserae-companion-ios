import Foundation
import Testing
@testable import TesseraeKit

@MainActor
struct DisplayOrderPreferencesTests {
    @Test func independentReadersSeeReordersWithinTheSameServer() throws {
        let suite = "DisplayOrderPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = DisplayOrderPreferences(defaults: defaults)
        let share = DisplayOrderPreferences(
            defaults: try #require(UserDefaults(suiteName: suite))
        )
        let displays = [display("desk", "Desk"), display("kitchen", "Kitchen")]

        app.save(["kitchen", "desk"], for: "home")
        #expect(share.orderedDisplays(displays, for: "home").map(\.id) == ["kitchen", "desk"])
        #expect(share.orderedDisplays(displays, for: "studio").map(\.id) == ["desk", "kitchen"])

        app.save(["desk", "kitchen"], for: "home")
        #expect(share.orderedDisplays(displays, for: "home").map(\.id) == ["desk", "kitchen"])
    }

    @Test func migratesExistingPrivateOrderToSharedPreferences() throws {
        let suite = "DisplayOrderPreferencesTests.\(UUID().uuidString)"
        let shared = try #require(UserDefaults(suiteName: suite))
        let legacy = try #require(UserDefaults(suiteName: suite + ".legacy"))
        defer {
            shared.removePersistentDomain(forName: suite)
            legacy.removePersistentDomain(forName: suite + ".legacy")
        }
        legacy.set(["kitchen", "desk"], forKey: "display-order.home")
        let app = DisplayOrderPreferences(defaults: shared)

        #expect(app.load(for: "home", migratingFrom: legacy) == ["kitchen", "desk"])
        #expect(legacy.object(forKey: "display-order.home") == nil)
        let share = DisplayOrderPreferences(
            defaults: try #require(UserDefaults(suiteName: suite))
        )
        #expect(share.load(for: "home") == ["kitchen", "desk"])

        legacy.set(["desk", "kitchen"], forKey: "display-order.home")
        #expect(app.load(for: "home", migratingFrom: legacy) == ["kitchen", "desk"])
    }

    @Test func standardPreferencesRetainExistingOrdersWithoutMigration() throws {
        let suite = "DisplayOrderPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["kitchen", "desk"], forKey: "display-order.home")
        let preferences = DisplayOrderPreferences(defaults: defaults)
        #expect(preferences.load(for: "home", migratingFrom: defaults) == ["kitchen", "desk"])
        #expect(preferences.load(for: "home") == ["kitchen", "desk"])
    }

    @Test func missingAndDuplicateSavedIDsKeepNewDisplaysInNameOrder() {
        let displays = [
            display("ten", "Frame 10"), display("two", "Frame 2"),
            display("b", "Desk"), display("a", "Desk"),
            display("kitchen", "Kitchen"),
        ]
        let ordered = DisplayOrderPreferences.orderedDisplays(
            displays, preferredIDs: ["removed", "kitchen", "kitchen", "b"]
        )
        #expect(ordered.map(\.id) == ["kitchen", "b", "a", "two", "ten"])
        #expect(DisplayOrderPreferences.orderedDisplays(displays, preferredIDs: []).map(\.id)
            == ["a", "b", "two", "ten", "kitchen"])
    }

    private func display(_ id: String, _ name: String) -> DisplaySummary {
        DisplaySummary(
            id: id, name: name, kind: "test_panel", iconName: "display",
            panel: PanelProfile(width: 800, height: 480, gamut: "gray_16", orientation: "landscape"),
            freshness: .stale
        )
    }
}
