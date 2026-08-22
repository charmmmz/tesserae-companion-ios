@preconcurrency import EventKit
import CryptoKit
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
    var changeNotificationObject: AnyObject { get }

    func requestFullAccess() async throws -> Bool
    func lists() -> [RemindersListDescriptor]
    func incompleteItems(in listID: String) async throws -> [ReminderSourceItem]
}

@MainActor
final class EventKitRemindersStore: RemindersAccessing {
    private let eventStore = EKEventStore()

    var changeNotificationObject: AnyObject {
        eventStore
    }

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
    static let maximumListCount = 20

    struct SourceList: Equatable, Sendable {
        let id: String
        let title: String
        let items: [ReminderSourceItem]
    }

    static func makeSnapshot(
        from sourceLists: [SourceList],
        generatedAt: Date = .now,
        serverMaximumTTLSeconds: Int?
    ) -> RemindersSnapshot {
        let ttlSeconds = maximumTTL(serverMaximumTTLSeconds)
        var remainingItems = maximumItemCount
        var lists: [ReminderListSnapshot] = []

        for sourceList in sourceLists.prefix(maximumListCount) {
            let id = bounded(
                sourceList.id.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumCharacters: 256
            )
            let title = bounded(
                sourceList.title.trimmingCharacters(in: .whitespacesAndNewlines),
                maximumCharacters: 256
            )
            guard !id.isEmpty, !title.isEmpty else { continue }

            let items = normalizedItems(sourceList.items)
                .prefix(remainingItems)
            lists.append(
                ReminderListSnapshot(
                    id: id,
                    title: title,
                    items: Array(items)
                )
            )
            remainingItems -= items.count
        }

        return RemindersSnapshot(
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(TimeInterval(ttlSeconds)),
            data: RemindersData(lists: lists)
        )
    }

    private static func normalizedItems(
        _ sourceItems: [ReminderSourceItem]
    ) -> [ReminderSnapshotItem] {
        sourceItems
            .filter { !$0.isCompleted }
            .compactMap(snapshotItem)
            .sorted(by: precedes)
    }

    private static func maximumTTL(_ serverMaximumTTLSeconds: Int?) -> Int {
        max(
            1,
            min(
                serverMaximumTTLSeconds ?? privacyTTLSeconds,
                privacyTTLSeconds
            )
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
    var selectedListIDs: [String]
    var selectedListTitles: [String: String]
    var publicationIDs: [String: String]
    var lastSuccessfulContentDigest: String?
    var lastSuccessfulListIDs: [String]?
    var lastSuccessfulItemCount: Int?
    var lastSuccessfulListItemCounts: [String: Int]?
    var isEnabled: Bool

    init(
        instanceID: String,
        selectedListIDs: [String] = [],
        selectedListTitles: [String: String] = [:],
        publicationIDs: [String: String] = [:],
        lastSuccessfulContentDigest: String? = nil,
        lastSuccessfulListIDs: [String]? = nil,
        lastSuccessfulItemCount: Int? = nil,
        lastSuccessfulListItemCounts: [String: Int]? = nil,
        isEnabled: Bool = false
    ) {
        self.instanceID = instanceID
        self.selectedListIDs = selectedListIDs
        self.selectedListTitles = selectedListTitles
        self.publicationIDs = publicationIDs
        self.lastSuccessfulContentDigest = lastSuccessfulContentDigest
        self.lastSuccessfulListIDs = lastSuccessfulListIDs
        self.lastSuccessfulItemCount = lastSuccessfulItemCount
        self.lastSuccessfulListItemCounts = lastSuccessfulListItemCounts
        self.isEnabled = isEnabled
    }
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
                instanceID: instanceID
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
    case tooManyLists
    case unavailable

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            String(
                localized: "Reminders full access is required to read the selected lists."
            )
        case .listRequired:
            String(
                localized: "Choose at least one Reminders list before enabling sync."
            )
        case .listUnavailable:
            String(
                localized: "One or more selected Reminders lists are no longer available."
            )
        case .serverUnsupported:
            String(
                localized: "This Tesserae server does not advertise Reminders personal data support."
            )
        case .tooManyLists:
            String(localized: "You can sync up to 20 Reminders lists.")
        case .unavailable:
            String(localized: "A connected Tesserae instance is required.")
        }
    }
}

@MainActor
@Observable
final class RemindersBridgeModel {
    struct UnavailableSelectedList: Identifiable, Equatable {
        let id: String
        let title: String
    }

    private let reminders: any RemindersAccessing
    private let preferencesStore: RemindersBridgePreferencesStore
    private let notificationCenter: NotificationCenter
    private let changeDebounceDuration: Duration
    private var instanceID: String?
    private weak var monitoringAppModel: AppModel?
    private var eventStoreObserver: NSObjectProtocol?
    private var changeDebounceTask: Task<Void, Never>?
    private var applicationIsActive = false
    private var hasPendingAutomaticRefresh = false

    var authorizationState: RemindersAuthorizationState = .notDetermined
    var lists: [RemindersListDescriptor] = []
    var selectedListIDs: Set<String> = []
    private var selectedListTitles: [String: String] = [:]
    private var publicationIDs: [String: String] = [:]
    private var lastSuccessfulContentDigest: String?
    private var lastSuccessfulListIDs: Set<String> = []
    var isEnabled = false
    var isBusy = false
    var itemCount: Int?
    var listItemCounts: [String: Int] = [:]
    var sourceStatus: PersonalDataSourceStatus?
    var confirmationMessage: String?
    var errorMessage: String?

    var includedListCount: Int? {
        sourceStatus == nil ? nil : lastSuccessfulListIDs.count
    }

    var hasPendingSelectionChanges: Bool {
        isEnabled && selectedListIDs != lastSuccessfulListIDs
    }

    var unavailableSelectedLists: [UnavailableSelectedList] {
        let availableIDs = Set(lists.map(\.id))
        return selectedListIDs
            .filter { !availableIDs.contains($0) }
            .map {
                UnavailableSelectedList(
                    id: $0,
                    title: selectedListTitles[$0] ?? String(localized: "Unknown List")
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

    init(
        reminders: any RemindersAccessing = EventKitRemindersStore(),
        preferencesStore: RemindersBridgePreferencesStore = .init(),
        notificationCenter: NotificationCenter = .default,
        changeDebounceDuration: Duration = .seconds(2)
    ) {
        self.reminders = reminders
        self.preferencesStore = preferencesStore
        self.notificationCenter = notificationCenter
        self.changeDebounceDuration = changeDebounceDuration
    }

    func startChangeMonitoring(
        using appModel: AppModel,
        applicationIsActive: Bool
    ) {
        monitoringAppModel = appModel
        self.applicationIsActive = applicationIsActive
        if eventStoreObserver == nil {
            eventStoreObserver = notificationCenter.addObserver(
                forName: .EKEventStoreChanged,
                object: reminders.changeNotificationObject,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventStoreDidChange()
                }
            }
        }
        requestAutomaticRefresh()
    }

    func updateApplicationActivity(
        _ isActive: Bool,
        using appModel: AppModel
    ) {
        monitoringAppModel = appModel
        applicationIsActive = isActive
        if isActive {
            requestAutomaticRefresh()
        } else {
            changeDebounceTask?.cancel()
            changeDebounceTask = nil
        }
    }

    func stopChangeMonitoring() {
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        if let eventStoreObserver {
            notificationCenter.removeObserver(eventStoreObserver)
            self.eventStoreObserver = nil
        }
        monitoringAppModel = nil
    }

    func eventStoreDidChange() {
        requestAutomaticRefresh()
    }

    private func requestAutomaticRefresh() {
        guard isEnabled else { return }
        hasPendingAutomaticRefresh = true
        schedulePendingRefreshIfPossible()
    }

    private func schedulePendingRefreshIfPossible() {
        guard
            hasPendingAutomaticRefresh,
            applicationIsActive,
            monitoringAppModel != nil
        else {
            return
        }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: changeDebounceDuration)
            } catch {
                return
            }
            changeDebounceTask = nil
            await synchronizePendingAutomaticRefresh()
        }
    }

    private func synchronizePendingAutomaticRefresh() async {
        guard
            hasPendingAutomaticRefresh,
            applicationIsActive,
            isEnabled,
            authorizationState == .fullAccess,
            let appModel = monitoringAppModel,
            appModel.supportsRemindersPersonalData
        else {
            return
        }
        if isBusy {
            schedulePendingRefreshIfPossible()
            return
        }

        hasPendingAutomaticRefresh = false
        reloadLists()
        await synchronize(
            using: appModel,
            enabling: false,
            forceUpload: false
        )
        schedulePendingRefreshIfPossible()
    }

    func load(using appModel: AppModel) async {
        errorMessage = nil
        guard let currentInstanceID = appModel.activeInstance?.id else {
            errorMessage = RemindersBridgeError.unavailable.localizedDescription
            return
        }
        instanceID = currentInstanceID
        let preferences = preferencesStore.preferences(for: currentInstanceID)
        selectedListIDs = Set(preferences.selectedListIDs)
        selectedListTitles = preferences.selectedListTitles
        publicationIDs = preferences.publicationIDs
        lastSuccessfulContentDigest = preferences.lastSuccessfulContentDigest
        lastSuccessfulListIDs = Set(
            preferences.lastSuccessfulListIDs
                ?? (preferences.lastSuccessfulContentDigest == nil
                    ? []
                    : preferences.selectedListIDs)
        )
        itemCount = preferences.lastSuccessfulItemCount
        listItemCounts = preferences.lastSuccessfulListItemCounts ?? [:]
        isEnabled = preferences.isEnabled
        authorizationState = reminders.authorizationState
        if authorizationState == .fullAccess {
            reloadLists()
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
            reloadLists()
        } catch {
            authorizationState = reminders.authorizationState
            errorMessage = error.localizedDescription
        }
    }

    func toggleList(_ listID: String) {
        if selectedListIDs.contains(listID) {
            selectedListIDs.remove(listID)
        } else {
            guard selectedListIDs.count < ReminderSnapshotFactory.maximumListCount else {
                errorMessage = RemindersBridgeError.tooManyLists.localizedDescription
                return
            }
            selectedListIDs.insert(listID)
            if publicationIDs[listID] == nil {
                publicationIDs[listID] = UUID().uuidString.lowercased()
            }
        }
        confirmationMessage = nil
        errorMessage = nil
        savePreferences()
    }

    func removeUnavailableList(_ listID: String) {
        let availableIDs = Set(lists.map(\.id))
        guard
            !availableIDs.contains(listID),
            selectedListIDs.remove(listID) != nil
        else {
            return
        }
        confirmationMessage = nil
        errorMessage = nil
        savePreferences()
    }

    func enableAndSync(using appModel: AppModel) async {
        await synchronize(
            using: appModel,
            enabling: true,
            forceUpload: true
        )
    }

    func syncNow(using appModel: AppModel) async {
        await synchronize(
            using: appModel,
            enabling: false,
            forceUpload: true
        )
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
            listItemCounts = [:]
            lastSuccessfulContentDigest = nil
            lastSuccessfulListIDs = []
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
        enabling: Bool,
        forceUpload: Bool
    ) async {
        guard appModel.supportsRemindersPersonalData else {
            errorMessage = RemindersBridgeError.serverUnsupported.localizedDescription
            return
        }
        guard authorizationState == .fullAccess else {
            errorMessage = RemindersBridgeError.accessDenied.localizedDescription
            return
        }
        guard !enabling || !selectedListIDs.isEmpty else {
            errorMessage = RemindersBridgeError.listRequired.localizedDescription
            return
        }
        let selectedLists = lists.filter { selectedListIDs.contains($0.id) }
        guard selectedLists.count == selectedListIDs.count else {
            errorMessage = RemindersBridgeError.listUnavailable.localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        if forceUpload {
            confirmationMessage = nil
        }
        defer { isBusy = false }

        do {
            var sourceLists: [ReminderSnapshotFactory.SourceList] = []
            for list in selectedLists {
                let sourceItems = try await reminders.incompleteItems(in: list.id)
                sourceLists.append(
                    ReminderSnapshotFactory.SourceList(
                        id: publicationID(for: list.id),
                        title: list.title,
                        items: sourceItems
                    )
                )
            }
            let snapshot = ReminderSnapshotFactory.makeSnapshot(
                from: sourceLists,
                serverMaximumTTLSeconds: appModel.personalDataMaximumTTLSeconds
            )
            let contentDigest = try Self.contentDigest(for: snapshot.data)

            var uploadIsRequired = forceUpload
                || contentDigest != lastSuccessfulContentDigest
            if !uploadIsRequired {
                sourceStatus = try await appModel.remindersPersonalDataStatus()
                uploadIsRequired = Self.automaticUploadIsRequired(
                    contentDigest: contentDigest,
                    lastSuccessfulContentDigest: lastSuccessfulContentDigest,
                    sourceStatus: sourceStatus
                )
            }

            guard uploadIsRequired else {
                recordSuccessfulSnapshot(
                    snapshot,
                    selectedLists: selectedLists,
                    contentDigest: contentDigest
                )
                savePreferences()
                return
            }
            sourceStatus = try await appModel.putRemindersSnapshot(snapshot)
            recordSuccessfulSnapshot(
                snapshot,
                selectedLists: selectedLists,
                contentDigest: contentDigest
            )
            if enabling {
                isEnabled = true
            }
            savePreferences()
            if forceUpload {
                confirmationMessage = String(
                    localized: "Synced \(itemCount ?? 0) incomplete reminders from \(selectedLists.count) list(s)."
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func recordSuccessfulSnapshot(
        _ snapshot: RemindersSnapshot,
        selectedLists: [RemindersListDescriptor],
        contentDigest: String
    ) {
        lastSuccessfulContentDigest = contentDigest
        lastSuccessfulListIDs = Set(selectedLists.map(\.id))
        itemCount = snapshot.data.lists.reduce(0) { $0 + $1.items.count }
        listItemCounts = Dictionary(
            uniqueKeysWithValues: zip(selectedLists, snapshot.data.lists).map {
                list, listSnapshot in
                (list.id, listSnapshot.items.count)
            }
        )
    }

    static func contentDigest(for data: RemindersData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(data)
        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func automaticUploadIsRequired(
        contentDigest: String,
        lastSuccessfulContentDigest: String?,
        sourceStatus: PersonalDataSourceStatus?
    ) -> Bool {
        contentDigest != lastSuccessfulContentDigest
            || sourceStatus?.state != .fresh
    }

    private func reloadLists() {
        lists = reminders.lists()
        if !selectedListIDs.isEmpty {
            for list in lists where selectedListIDs.contains(list.id) {
                selectedListTitles[list.id] = list.title
                if publicationIDs[list.id] == nil {
                    publicationIDs[list.id] = UUID().uuidString.lowercased()
                }
            }
            savePreferences()
            return
        }
        savePreferences()
    }

    private func publicationID(for eventKitListID: String) -> String {
        if let existing = publicationIDs[eventKitListID] {
            return existing
        }
        let newID = UUID().uuidString.lowercased()
        publicationIDs[eventKitListID] = newID
        return newID
    }

    private func savePreferences() {
        guard let instanceID else { return }
        for list in lists where selectedListIDs.contains(list.id) {
            selectedListTitles[list.id] = list.title
        }
        let orderedIDs = lists
            .filter { selectedListIDs.contains($0.id) }
            .map(\.id)
            + selectedListIDs
                .filter { id in !lists.contains(where: { $0.id == id }) }
                .sorted()
        preferencesStore.save(
            RemindersBridgePreferences(
                instanceID: instanceID,
                selectedListIDs: orderedIDs,
                selectedListTitles: selectedListTitles,
                publicationIDs: publicationIDs,
                lastSuccessfulContentDigest: lastSuccessfulContentDigest,
                lastSuccessfulListIDs: lastSuccessfulListIDs.sorted(),
                lastSuccessfulItemCount: itemCount,
                lastSuccessfulListItemCounts: listItemCounts,
                isEnabled: isEnabled
            )
        )
    }
}
