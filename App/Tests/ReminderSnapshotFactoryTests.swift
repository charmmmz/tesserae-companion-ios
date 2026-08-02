@preconcurrency import EventKit
import Foundation
import XCTest
@testable import Tesserae_Companion

final class ReminderSnapshotFactoryTests: XCTestCase {
    func testEventKitFetchCompletionCanRunOnBackgroundQueue() async {
        let items: [ReminderSourceItem] = await withCheckedContinuation {
            continuation in
            let completion = EventKitRemindersStore.makeFetchCompletion(
                continuation
            )
            DispatchQueue.global().async {
                let eventStore = EKEventStore()
                let reminder = EKReminder(eventStore: eventStore)
                reminder.title = "Milk"
                reminder.priority = 5
                reminder.dueDateComponents = DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    year: 2026,
                    month: 8,
                    day: 4
                )
                completion([reminder])
            }
        }

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Milk")
        XCTAssertEqual(items[0].priority, 5)
        XCTAssertEqual(items[0].dueDateComponents?.day, 4)
    }

    func testSnapshotFiltersAndNormalizesReminderFields() {
        let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let source = [
            ReminderSourceItem(
                id: " milk-id ",
                title: " Milk ",
                dueDateComponents: DateComponents(
                    calendar: Calendar(identifier: .gregorian),
                    year: 2026,
                    month: 8,
                    day: 3
                ),
                priority: 1,
                isCompleted: false
            ),
            ReminderSourceItem(
                id: "bread-id",
                title: "Bread",
                dueDateComponents: nil,
                priority: 7,
                isCompleted: false
            ),
            ReminderSourceItem(
                id: "done-id",
                title: "Already eaten",
                dueDateComponents: nil,
                priority: 5,
                isCompleted: true
            ),
            ReminderSourceItem(
                id: "empty-id",
                title: "   ",
                dueDateComponents: nil,
                priority: 0,
                isCompleted: false
            ),
        ]

        let snapshot = ReminderSnapshotFactory.makeSnapshot(
            from: source,
            generatedAt: generatedAt,
            serverMaximumTTLSeconds: 86_400
        )

        XCTAssertEqual(snapshot.data.items.map(\.id), ["milk-id", "bread-id"])
        XCTAssertEqual(snapshot.data.items.map(\.title), ["Milk", "Bread"])
        XCTAssertEqual(snapshot.data.items[0].dueDate, "2026-08-03")
        XCTAssertEqual(snapshot.data.items[0].priority, .high)
        XCTAssertEqual(snapshot.data.items[1].priority, .low)
        XCTAssertTrue(snapshot.data.items.allSatisfy { !$0.completed })
        XCTAssertEqual(
            snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt),
            86_400,
            accuracy: 0.001
        )
    }

    func testSnapshotCapsPrivacyTTLAndItemCount() {
        let source = (0..<240).map { index in
            ReminderSourceItem(
                id: "item-\(index)",
                title: "Item \(index)",
                dueDateComponents: nil,
                priority: 0,
                isCompleted: false
            )
        }
        let snapshot = ReminderSnapshotFactory.makeSnapshot(
            from: source,
            generatedAt: .now,
            serverMaximumTTLSeconds: 7 * 24 * 60 * 60
        )

        XCTAssertEqual(snapshot.data.items.count, 200)
        XCTAssertEqual(
            snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt),
            48 * 60 * 60,
            accuracy: 0.001
        )
    }

    @MainActor
    func testPreferencesRoundTripPerInstance() throws {
        let suiteName = "ReminderSnapshotFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = RemindersBridgePreferencesStore(
            defaults: defaults,
            keyPrefix: "test-reminders"
        )
        let preferences = RemindersBridgePreferences(
            instanceID: "home",
            listID: "grocery-list",
            listTitle: "Grocery List",
            isEnabled: true
        )

        store.save(preferences)

        XCTAssertEqual(store.preferences(for: "home"), preferences)
        XCTAssertFalse(store.preferences(for: "other").isEnabled)
    }
}
