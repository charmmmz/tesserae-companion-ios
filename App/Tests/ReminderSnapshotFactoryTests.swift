@preconcurrency import EventKit
import Foundation
import TesseraeKit
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
            from: [
                .init(id: "public-list", title: "Grocery List", items: source),
            ],
            generatedAt: generatedAt,
            serverMaximumTTLSeconds: 86_400
        )
        let items = snapshot.data.lists[0].items

        XCTAssertEqual(items.map(\.id), ["milk-id", "bread-id"])
        XCTAssertEqual(items.map(\.title), ["Milk", "Bread"])
        XCTAssertEqual(items[0].dueDate, "2026-08-03")
        XCTAssertEqual(items[0].priority, .high)
        XCTAssertEqual(items[1].priority, .low)
        XCTAssertTrue(items.allSatisfy { !$0.completed })
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
            from: [
                .init(id: "public-list", title: "Grocery List", items: source),
            ],
            generatedAt: .now,
            serverMaximumTTLSeconds: 7 * 24 * 60 * 60
        )

        XCTAssertEqual(snapshot.data.lists[0].items.count, 200)
        XCTAssertEqual(
            snapshot.expiresAt.timeIntervalSince(snapshot.generatedAt),
            48 * 60 * 60,
            accuracy: 0.001
        )
    }

    func testMultiListSnapshotGroupsListsAndCapsAggregateItems() {
        let sourceItems = (0..<150).map { index in
            ReminderSourceItem(
                id: "item-\(index)",
                title: "Item \(index)",
                dueDateComponents: nil,
                priority: 0,
                isCompleted: false
            )
        }
        let snapshot = ReminderSnapshotFactory.makeSnapshot(
            from: [
                .init(id: "public-a", title: "Groceries", items: sourceItems),
                .init(id: "public-b", title: "Weekend", items: sourceItems),
            ],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            serverMaximumTTLSeconds: nil
        )

        XCTAssertEqual(snapshot.sourceID, .reminders)
        XCTAssertEqual(snapshot.data.lists.map(\.title), ["Groceries", "Weekend"])
        XCTAssertEqual(snapshot.data.lists[0].items.count, 150)
        XCTAssertEqual(snapshot.data.lists[1].items.count, 50)
        XCTAssertEqual(
            snapshot.data.lists.reduce(0) { $0 + $1.items.count },
            200
        )
    }

    func testSnapshotAllowsAnEmptyPublishedListSet() {
        let snapshot = ReminderSnapshotFactory.makeSnapshot(
            from: [],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            serverMaximumTTLSeconds: nil
        )

        XCTAssertEqual(snapshot.sourceID, .reminders)
        XCTAssertEqual(snapshot.data.lists, [])
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
            selectedListIDs: ["grocery-list", "weekend-list"],
            selectedListTitles: [
                "grocery-list": "Grocery List",
                "weekend-list": "Weekend",
            ],
            publicationIDs: ["grocery-list": "public-grocery"],
            lastSuccessfulContentDigest: "digest-1",
            isEnabled: true
        )

        store.save(preferences)

        XCTAssertEqual(store.preferences(for: "home"), preferences)
        XCTAssertFalse(store.preferences(for: "other").isEnabled)
        XCTAssertTrue(store.preferences(for: "other").selectedListIDs.isEmpty)
    }

    @MainActor
    func testPreferencesWithoutContentDigestStillDecode() throws {
        let encoded = try XCTUnwrap(
            """
            {
              "instanceID": "home",
              "selectedListIDs": ["grocery-list"],
              "selectedListTitles": {"grocery-list": "Grocery List"},
              "publicationIDs": {"grocery-list": "public-grocery"},
              "isEnabled": true
            }
            """.data(using: .utf8)
        )

        let preferences = try JSONDecoder().decode(
            RemindersBridgePreferences.self,
            from: encoded
        )

        XCTAssertTrue(preferences.isEnabled)
        XCTAssertNil(preferences.lastSuccessfulContentDigest)
    }

    @MainActor
    func testContentDigestChangesOnlyWhenPublishedReminderDataChanges() throws {
        let data = RemindersData(
            lists: [
                ReminderListSnapshot(
                    id: "public-grocery",
                    title: "Grocery List",
                    items: [
                        ReminderSnapshotItem(
                            id: "milk",
                            title: "Milk",
                            dueDate: "2026-08-04",
                            priority: .medium
                        ),
                    ]
                ),
            ]
        )
        let changedData = RemindersData(
            lists: [
                ReminderListSnapshot(
                    id: "public-grocery",
                    title: "Grocery List",
                    items: [
                        ReminderSnapshotItem(
                            id: "milk",
                            title: "Oat Milk",
                            dueDate: "2026-08-04",
                            priority: .medium
                        ),
                    ]
                ),
            ]
        )

        let digest = try RemindersBridgeModel.contentDigest(for: data)

        XCTAssertEqual(
            digest,
            try RemindersBridgeModel.contentDigest(for: data)
        )
        XCTAssertNotEqual(
            digest,
            try RemindersBridgeModel.contentDigest(for: changedData)
        )
        XCTAssertEqual(digest.count, 64)
    }

    @MainActor
    func testAutomaticUploadDecisionRequiresChangeOrNonFreshServerSnapshot() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let freshStatus = PersonalDataSourceStatus(
            sourceID: .reminders,
            state: .fresh,
            generatedAt: now,
            staleAt: now.addingTimeInterval(86_400),
            expiresAt: now.addingTimeInterval(172_800)
        )
        let staleStatus = PersonalDataSourceStatus(
            sourceID: .reminders,
            state: .stale,
            generatedAt: now,
            staleAt: now,
            expiresAt: now.addingTimeInterval(86_400)
        )

        XCTAssertFalse(
            RemindersBridgeModel.automaticUploadIsRequired(
                contentDigest: "same",
                lastSuccessfulContentDigest: "same",
                sourceStatus: freshStatus
            )
        )
        XCTAssertTrue(
            RemindersBridgeModel.automaticUploadIsRequired(
                contentDigest: "changed",
                lastSuccessfulContentDigest: "same",
                sourceStatus: freshStatus
            )
        )
        XCTAssertTrue(
            RemindersBridgeModel.automaticUploadIsRequired(
                contentDigest: "same",
                lastSuccessfulContentDigest: "same",
                sourceStatus: staleStatus
            )
        )
        XCTAssertTrue(
            RemindersBridgeModel.automaticUploadIsRequired(
                contentDigest: "same",
                lastSuccessfulContentDigest: "same",
                sourceStatus: nil
            )
        )
    }

    @MainActor
    func testGrantingAccessDoesNotAutoSelectAnyList() async {
        let reminders = TestRemindersStore(
            lists: [
                RemindersListDescriptor(id: "grocery-list", title: "Grocery List"),
            ]
        )
        let model = RemindersBridgeModel(reminders: reminders)

        await model.requestAccess()

        XCTAssertEqual(model.lists, reminders.lists())
        XCTAssertTrue(model.selectedListIDs.isEmpty)
    }

    @MainActor
    func testEnabledBridgeCanSyncAnEmptyPublishedListSet() async throws {
        let suiteName = "ReminderSnapshotFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = RemindersBridgePreferencesStore(
            defaults: defaults,
            keyPrefix: "test-reminders"
        )
        preferencesStore.save(
            RemindersBridgePreferences(
                instanceID: "home",
                isEnabled: true
            )
        )
        let reminders = TestRemindersStore(
            lists: [],
            authorizationState: .fullAccess
        )
        let model = RemindersBridgeModel(
            reminders: reminders,
            preferencesStore: preferencesStore
        )
        let appModel = makeRemindersAppModel()

        await model.load(using: appModel)
        await model.syncNow(using: appModel)

        XCTAssertTrue(model.isEnabled)
        XCTAssertTrue(model.selectedListIDs.isEmpty)
        XCTAssertEqual(model.itemCount, 0)
        XCTAssertEqual(model.sourceStatus?.state, .fresh)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(
            model.confirmationMessage,
            "Synced 0 incomplete reminders from 0 list(s)."
        )
    }

    @MainActor
    func testForegroundCatchUpAndQueuedEventKitChangesShareOnePath() async throws {
        let suiteName = "ReminderSnapshotFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = RemindersBridgePreferencesStore(
            defaults: defaults,
            keyPrefix: "test-reminders"
        )
        preferencesStore.save(
            RemindersBridgePreferences(
                instanceID: "home",
                selectedListIDs: ["grocery-list"],
                selectedListTitles: ["grocery-list": "Grocery List"],
                publicationIDs: ["grocery-list": "public-grocery"],
                isEnabled: true
            )
        )
        let reminders = TestRemindersStore(
            lists: [
                RemindersListDescriptor(
                    id: "grocery-list",
                    title: "Grocery List"
                ),
            ],
            authorizationState: .fullAccess
        )
        let notificationCenter = NotificationCenter()
        let model = RemindersBridgeModel(
            reminders: reminders,
            preferencesStore: preferencesStore,
            notificationCenter: notificationCenter,
            changeDebounceDuration: .zero
        )
        let appModel = makeRemindersAppModel()

        await model.load(using: appModel)
        model.startChangeMonitoring(
            using: appModel,
            applicationIsActive: false
        )
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(reminders.incompleteItemsFetchCount, 0)

        model.updateApplicationActivity(true, using: appModel)
        for _ in 0..<100 where model.sourceStatus == nil {
            await Task.yield()
        }
        XCTAssertEqual(reminders.incompleteItemsFetchCount, 1)

        model.updateApplicationActivity(false, using: appModel)
        notificationCenter.post(
            name: .EKEventStoreChanged,
            object: reminders.changeNotificationObject
        )
        notificationCenter.post(
            name: .EKEventStoreChanged,
            object: reminders.changeNotificationObject
        )
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(reminders.incompleteItemsFetchCount, 1)

        model.updateApplicationActivity(true, using: appModel)
        for _ in 0..<100 where reminders.incompleteItemsFetchCount < 2 {
            await Task.yield()
        }

        XCTAssertEqual(reminders.incompleteItemsFetchCount, 2)
        XCTAssertEqual(model.sourceStatus?.state, .fresh)
        XCTAssertNil(model.errorMessage)
        model.stopChangeMonitoring()
    }

    @MainActor
    func testDeletedSelectedListCanBeRemovedAndRemainingListsSynced() async throws {
        let suiteName = "ReminderSnapshotFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferencesStore = RemindersBridgePreferencesStore(
            defaults: defaults,
            keyPrefix: "test-reminders"
        )
        preferencesStore.save(
            RemindersBridgePreferences(
                instanceID: "home",
                selectedListIDs: ["grocery-list", "deleted-todo-list"],
                selectedListTitles: [
                    "grocery-list": "Grocery List",
                    "deleted-todo-list": "TODO",
                ],
                publicationIDs: [
                    "grocery-list": "public-grocery",
                    "deleted-todo-list": "public-todo",
                ],
                isEnabled: true
            )
        )
        let reminders = TestRemindersStore(
            lists: [
                RemindersListDescriptor(
                    id: "grocery-list",
                    title: "Grocery List"
                ),
            ],
            authorizationState: .fullAccess
        )
        let model = RemindersBridgeModel(
            reminders: reminders,
            preferencesStore: preferencesStore
        )
        let appModel = makeRemindersAppModel()

        await model.load(using: appModel)
        XCTAssertEqual(
            model.unavailableSelectedLists,
            [.init(id: "deleted-todo-list", title: "TODO")]
        )

        model.removeUnavailableList("deleted-todo-list")
        await model.syncNow(using: appModel)

        XCTAssertEqual(model.selectedListIDs, ["grocery-list"])
        XCTAssertTrue(model.unavailableSelectedLists.isEmpty)
        XCTAssertEqual(reminders.incompleteItemsFetchCount, 1)
        XCTAssertEqual(model.sourceStatus?.state, .fresh)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    private func makeRemindersAppModel() -> AppModel {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        let model = AppModel(
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
        model.activeInstance = TesseraeInstance(
            id: "home",
            name: "Home",
            baseURL: URL(string: "http://tesserae.test")!,
            serverVersion: "0.240.0",
            timezone: "UTC",
            webURL: "/"
        )
        model.connectionMode = .live
        model.capabilities = ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.240.0",
            api: CompanionAPI(version: 1),
            pairing: PairingCapabilities(
                supported: true,
                codeLength: 6,
                ttlSeconds: 600
            ),
            features: [],
            personalData: PersonalDataCapabilities(sources: ["reminders"]),
            limits: CompanionLimits(
                imageUploadBytes: 1,
                imageMaxEdge: 1,
                imageContentTypes: ["image/png"],
                personalDataStaleAfterSeconds: 86_400,
                personalDataMaxTTLSeconds: 172_800,
                jobRetentionSeconds: 60,
                idempotencyRetentionSeconds: 60
            ),
            webURL: "/"
        )
        return model
    }
}

@MainActor
final class AppModelOrderingTests: XCTestCase {
    private let displayOrderKey = "display-order.demo-home"
    private let collapsedDashboardSectionsKey =
        "dashboard-collapsed-sections.demo-home"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: displayOrderKey)
        UserDefaults.standard.removeObject(
            forKey: collapsedDashboardSectionsKey
        )
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: displayOrderKey)
        UserDefaults.standard.removeObject(
            forKey: collapsedDashboardSectionsKey
        )
        super.tearDown()
    }

    func testDisplayOrderSurvivesRefreshAndReconnect() async {
        let model = makeAppModel()

        await model.connectDemo()
        XCTAssertEqual(
            model.sortedDisplays.map(\.id),
            ["e1004-desk", "picpak-kitchen"]
        )

        model.moveDisplay("picpak-kitchen", to: 0)
        XCTAssertEqual(
            model.sortedDisplays.map(\.id),
            ["picpak-kitchen", "e1004-desk"]
        )

        await model.refreshDisplays()
        XCTAssertEqual(
            model.sortedDisplays.map(\.id),
            ["picpak-kitchen", "e1004-desk"]
        )

        let restoredModel = makeAppModel()
        await restoredModel.connectDemo()
        XCTAssertEqual(
            restoredModel.sortedDisplays.map(\.id),
            ["picpak-kitchen", "e1004-desk"]
        )
    }

    func testCollapsedDashboardSectionsSurviveReconnect() async {
        let model = makeAppModel()

        await model.connectDemo()
        model.setDashboardSectionCollapsed(
            "display-picpak-kitchen",
            isCollapsed: true
        )
        model.setDashboardSectionCollapsed("shared", isCollapsed: true)

        let restoredModel = makeAppModel()
        await restoredModel.connectDemo()
        XCTAssertEqual(
            restoredModel.collapsedDashboardSectionIDs,
            ["display-picpak-kitchen", "shared"]
        )

        restoredModel.setDashboardSectionCollapsed(
            "display-picpak-kitchen",
            isCollapsed: false
        )
        XCTAssertEqual(
            restoredModel.collapsedDashboardSectionIDs,
            ["shared"]
        )
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

@MainActor
final class AppModelDashboardPreviewTests: XCTestCase {
    func testDashboardPreviewsRemainScopedToTheirTargetDisplay() async throws {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        let model = AppModel(
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

        await model.connectDemo()
        let dashboard = try XCTUnwrap(
            model.dashboards.first { $0.id == "photo-frame" }
        )

        await model.loadDashboardPreview(
            dashboard,
            deviceID: "picpak-kitchen"
        )
        await model.loadDashboardPreview(
            dashboard,
            deviceID: "e1004-desk"
        )

        XCTAssertEqual(
            model.dashboardPreview(
                for: dashboard,
                deviceID: "picpak-kitchen"
            )?.eTag,
            "\"dashboard-preview-photo-frame-picpak-kitchen\""
        )
        XCTAssertEqual(
            model.dashboardPreview(
                for: dashboard,
                deviceID: "e1004-desk"
            )?.eTag,
            "\"dashboard-preview-photo-frame-e1004-desk\""
        )
    }
}

@MainActor
private final class TestRemindersStore: RemindersAccessing {
    private(set) var authorizationState: RemindersAuthorizationState = .notDetermined
    private(set) var incompleteItemsFetchCount = 0
    private let availableLists: [RemindersListDescriptor]

    var changeNotificationObject: AnyObject {
        self
    }

    init(
        lists: [RemindersListDescriptor],
        authorizationState: RemindersAuthorizationState = .notDetermined
    ) {
        availableLists = lists
        self.authorizationState = authorizationState
    }

    func requestFullAccess() async throws -> Bool {
        authorizationState = .fullAccess
        return true
    }

    func lists() -> [RemindersListDescriptor] {
        availableLists
    }

    func incompleteItems(in listID: String) async throws -> [ReminderSourceItem] {
        incompleteItemsFetchCount += 1
        return []
    }
}
