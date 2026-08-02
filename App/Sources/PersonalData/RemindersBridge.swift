@preconcurrency import EventKit
import Foundation
import Observation
import TesseraeKit

enum RemindersAuthorizationState: Equatable {
    case notDetermined
    case denied
    case fullAccess
}

struct RemindersListDescriptor: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
}

struct ReminderSourceItem: Equatable, Sendable {
    let id: String
    let title: String
    let dueDateComponents: DateComponents?
    let priority: Int
    let isCompleted: Bool
}

@MainActor
protocol RemindersAccessing: AnyObject {
    var authorizationState: RemindersAuthorizationState { get }

    func requestFullAccess() async throws -> Bool
    func lists() -> [RemindersListDescriptor]
    func incompleteItems(in listID: String) async throws -> [ReminderSourceItem]
}

@MainActor
final class EventKitRemindersStore: RemindersAccessing {
    private let eventStore = EKEventStore()

    var authorizationState: RemindersAuthorizationState {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        if status == .fullAccess {
            return .fullAccess
        }
        if status == .notDetermined {
            return .notDetermined
        }
        return .denied
    }

    func requestFullAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToReminders()
    }

    func lists() -> [RemindersListDescriptor] {
        eventStore.calendars(for: .reminder)
            .map {
                RemindersListDescriptor(
                    id: $0.calendarIdentifier,
                    title: $0.title
                )
            }
            .sorted {
                let titleOrder = $0.title.localizedStandardCompare($1.title)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    func incompleteItems(in listID: String) async throws -> [ReminderSourceItem] {
        guard let list = eventStore.calendar(withIdentifier: listID) else {
            throw RemindersBridgeError.listUnavailable
        }
        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: [list]
        )

        return await withCheckedContinuation { continuation in
            eventStore.fetchReminders(
                matching: predicate,
                completion: Self.makeFetchCompletion(continuation)
            )
        }
    }

    nonisolated static func makeFetchCompletion(
        _ continuation: CheckedContinuation<[ReminderSourceItem], Never>
    ) -> @Sendable ([EKReminder]?) -> Void {
        { reminders in
            continuation.resume(
                returning: (reminders ?? []).map(sourceItem)
            )
        }
    }

    nonisolated private static func sourceItem(
        _ reminder: EKReminder
    ) -> ReminderSourceItem {
        ReminderSourceItem(
            id: reminder.calendarItemExternalIdentifier.isEmpty
                ? reminder.calendarItemIdentifier
                : reminder.calendarItemExternalIdentifier,
            title: reminder.title,
            dueDateComponents: reminder.dueDateComponents,
            priority: reminder.priority,
            isCompleted: reminder.isCompleted
        )
    }
}

enum ReminderSnapshotFactory {
    static let privacyTTLSeconds = 48 * 60 * 60
    static let maximumItemCount = 200

    static func makeSnapshot(
        from sourceItems: [ReminderSourceItem],
        generatedAt: Date = .now,
        serverMaximumTTLSeconds: Int?
    ) -> RemindersFridgeSnapshot {
        let ttlSeconds = max(
            1,
            min(
                serverMaximumTTLSeconds ?? privacyTTLSeconds,
                privacyTTLSeconds
            )
        )

        let items = sourceItems
            .filter { !$0.isCompleted }
            .compactMap(snapshotItem)
            .sorted(by: precedes)
            .prefix(maximumItemCount)

        return RemindersFridgeSnapshot(
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(TimeInterval(ttlSeconds)),
            data: RemindersFridgeData(items: Array(items))
        )
    }

    private static func snapshotItem(
        from source: ReminderSourceItem
    ) -> ReminderSnapshotItem? {
        let id = bounded(
            source.id.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumCharacters: 256
        )
        let title = bounded(
            source.title.trimmingCharacters(in: .whitespacesAndNewlines),
            maximumCharacters: 512
        )
        guard !id.isEmpty, !title.isEmpty else { return nil }

        return ReminderSnapshotItem(
            id: id,
            title: title,
            dueDate: formattedDate(source.dueDateComponents),
            priority: normalizedPriority(source.priority),
            completed: false
        )
    }

    private static func formattedDate(_ components: DateComponents?) -> String? {
        guard
            let components,
            let year = components.year,
            let month = components.month,
            let day = components.day,
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            return nil
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func normalizedPriority(_ priority: Int) -> ReminderSnapshotPriority {
        switch priority {
        case 1...4:
            .high
        case 5:
            .medium
        case 6...9:
            .low
        default:
            .none
        }
    }

    private static func precedes(
        _ lhs: ReminderSnapshotItem,
        _ rhs: ReminderSnapshotItem
    ) -> Bool {
        switch (lhs.dueDate, rhs.dueDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        default:
            if lhs.priority != rhs.priority {
                return priorityRank(lhs.priority) < priorityRank(rhs.priority)
            }
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.id < rhs.id
        }
    }

    private static func priorityRank(_ priority: ReminderSnapshotPriority) -> Int {
        switch priority {
        case .high: 0
        case .medium: 1
        case .low: 2
        case .none: 3
        }
    }

    private static func bounded(
        _ value: String,
        maximumCharacters: Int
    ) -> String {
        String(value.prefix(maximumCharacters))
    }
}

struct RemindersBridgePreferences: Codable, Equatable {
    let instanceID: String
    var listID: String?
    var listTitle: String?
    var isEnabled: Bool
}

@MainActor
final class RemindersBridgePreferencesStore {
    private let defaults: UserDefaults
    private let keyPrefix: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "TesseraeRemindersBridge"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    func preferences(for instanceID: String) -> RemindersBridgePreferences {
        guard
            let data = defaults.data(forKey: key(for: instanceID)),
            let preferences = try? JSONDecoder().decode(
                RemindersBridgePreferences.self,
                from: data
            )
        else {
            return RemindersBridgePreferences(
                instanceID: instanceID,
                listID: nil,
                listTitle: nil,
                isEnabled: false
            )
        }
        return preferences
    }

    func save(_ preferences: RemindersBridgePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(for: preferences.instanceID))
    }

    private func key(for instanceID: String) -> String {
        "\(keyPrefix).\(instanceID)"
    }
}

enum RemindersBridgeError: Error, LocalizedError {
    case accessDenied
    case listRequired
    case listUnavailable
    case serverUnsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            "Reminders full access is required to read the selected list."
        case .listRequired:
            "Choose a Reminders list before enabling sync."
        case .listUnavailable:
            "The selected Reminders list is no longer available."
        case .serverUnsupported:
            "This Tesserae server does not advertise Reminders personal data support."
        case .unavailable:
            "A connected Tesserae instance is required."
        }
    }
}

@MainActor
@Observable
final class RemindersBridgeModel {
    private let reminders: any RemindersAccessing
    private let preferencesStore: RemindersBridgePreferencesStore
    private var instanceID: String?

    var authorizationState: RemindersAuthorizationState = .notDetermined
    var lists: [RemindersListDescriptor] = []
    var selectedListID: String?
    var isEnabled = false
    var isBusy = false
    var itemCount: Int?
    var sourceStatus: PersonalDataSourceStatus?
    var confirmationMessage: String?
    var errorMessage: String?

    init(
        reminders: any RemindersAccessing = EventKitRemindersStore(),
        preferencesStore: RemindersBridgePreferencesStore = .init()
    ) {
        self.reminders = reminders
        self.preferencesStore = preferencesStore
    }

    func load(using appModel: AppModel) async {
        errorMessage = nil
        guard let currentInstanceID = appModel.activeInstance?.id else {
            errorMessage = RemindersBridgeError.unavailable.localizedDescription
            return
        }
        instanceID = currentInstanceID
        let preferences = preferencesStore.preferences(for: currentInstanceID)
        selectedListID = preferences.listID
        isEnabled = preferences.isEnabled
        authorizationState = reminders.authorizationState
        if authorizationState == .fullAccess {
            reloadLists(preferredTitle: preferences.listTitle)
        }
        guard appModel.supportsRemindersPersonalData else { return }
        do {
            sourceStatus = try await appModel.remindersPersonalDataStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestAccess() async {
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }

        do {
            guard try await reminders.requestFullAccess() else {
                throw RemindersBridgeError.accessDenied
            }
            authorizationState = reminders.authorizationState
            reloadLists(preferredTitle: "Grocery List")
        } catch {
            authorizationState = reminders.authorizationState
            errorMessage = error.localizedDescription
        }
    }

    func chooseList(_ listID: String) {
        selectedListID = listID.isEmpty ? nil : listID
        confirmationMessage = nil
        errorMessage = nil
        savePreferences()
    }

    func enableAndSync(using appModel: AppModel) async {
        await synchronize(using: appModel, enabling: true)
    }

    func syncNow(using appModel: AppModel) async {
        await synchronize(using: appModel, enabling: false)
    }

    func disableAndDelete(using appModel: AppModel) async {
        guard appModel.supportsRemindersPersonalData else {
            errorMessage = RemindersBridgeError.serverUnsupported.localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }

        do {
            try await appModel.deleteRemindersPersonalData()
            isEnabled = false
            sourceStatus = nil
            itemCount = nil
            savePreferences()
            confirmationMessage = String(
                localized: "Reminders sync is off and the server snapshot was deleted."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronize(
        using appModel: AppModel,
        enabling: Bool
    ) async {
        guard appModel.supportsRemindersPersonalData else {
            errorMessage = RemindersBridgeError.serverUnsupported.localizedDescription
            return
        }
        guard authorizationState == .fullAccess else {
            errorMessage = RemindersBridgeError.accessDenied.localizedDescription
            return
        }
        guard let selectedListID else {
            errorMessage = RemindersBridgeError.listRequired.localizedDescription
            return
        }

        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }

        do {
            let sourceItems = try await reminders.incompleteItems(
                in: selectedListID
            )
            let snapshot = ReminderSnapshotFactory.makeSnapshot(
                from: sourceItems,
                serverMaximumTTLSeconds: appModel.personalDataMaximumTTLSeconds
            )
            sourceStatus = try await appModel.putRemindersSnapshot(snapshot)
            itemCount = snapshot.data.items.count
            if enabling {
                isEnabled = true
            }
            savePreferences()
            confirmationMessage = String(
                localized: "Synced \(snapshot.data.items.count) incomplete reminders."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reloadLists(preferredTitle: String?) {
        lists = reminders.lists()
        if let selectedListID, lists.contains(where: { $0.id == selectedListID }) {
            return
        }
        selectedListID = lists.first {
            $0.title.compare(
                preferredTitle ?? "Grocery List",
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }?.id
        if selectedListID == nil, lists.count == 1 {
            selectedListID = lists[0].id
        }
        savePreferences()
    }

    private func savePreferences() {
        guard let instanceID else { return }
        let selectedList = lists.first { $0.id == selectedListID }
        preferencesStore.save(
            RemindersBridgePreferences(
                instanceID: instanceID,
                listID: selectedListID,
                listTitle: selectedList?.title,
                isEnabled: isEnabled
            )
        )
    }
}
