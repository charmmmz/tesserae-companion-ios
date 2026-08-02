import Foundation

public enum PersonalDataSourceID: String, Codable, CaseIterable, Hashable, Sendable {
    case remindersFridge = "reminders.fridge"

    public var capability: String {
        switch self {
        case .remindersFridge:
            "personal_data_reminders"
        }
    }
}

public enum PersonalDataSnapshotVersion: String, Codable, Hashable, Sendable {
    case v1 = "personal_data_bridge_v1"
}

public enum PersonalDataFreshness: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case expired
}

public enum ReminderSnapshotPriority: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case low
    case medium
    case high
}

public struct ReminderSnapshotItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let dueDate: String?
    public let priority: ReminderSnapshotPriority
    public let completed: Bool

    public init(
        id: String,
        title: String,
        dueDate: String?,
        priority: ReminderSnapshotPriority,
        completed: Bool = false
    ) {
        self.id = id
        self.title = title
        self.dueDate = dueDate
        self.priority = priority
        self.completed = completed
    }
}

public struct RemindersFridgeData: Codable, Hashable, Sendable {
    public let items: [ReminderSnapshotItem]

    public init(items: [ReminderSnapshotItem]) {
        self.items = items
    }
}

public struct RemindersFridgeSnapshot: Codable, Hashable, Sendable {
    public let version: PersonalDataSnapshotVersion
    public let sourceID: PersonalDataSourceID
    public let generatedAt: Date
    public let expiresAt: Date
    public let data: RemindersFridgeData

    public init(
        version: PersonalDataSnapshotVersion = .v1,
        sourceID: PersonalDataSourceID = .remindersFridge,
        generatedAt: Date,
        expiresAt: Date,
        data: RemindersFridgeData
    ) {
        self.version = version
        self.sourceID = sourceID
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourceID = "sourceId"
        case generatedAt
        case expiresAt
        case data
    }
}

public struct PersonalDataSourceStatus: Codable, Hashable, Sendable {
    public let sourceID: PersonalDataSourceID
    public let state: PersonalDataFreshness
    public let generatedAt: Date
    public let staleAt: Date
    public let expiresAt: Date

    public init(
        sourceID: PersonalDataSourceID,
        state: PersonalDataFreshness,
        generatedAt: Date,
        staleAt: Date,
        expiresAt: Date
    ) {
        self.sourceID = sourceID
        self.state = state
        self.generatedAt = generatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID = "sourceId"
        case state
        case generatedAt
        case staleAt
        case expiresAt
    }
}

public struct PersonalDataStatusResponse: Codable, Hashable, Sendable {
    public let sources: [PersonalDataSourceStatus]

    public init(sources: [PersonalDataSourceStatus]) {
        self.sources = sources
    }
}

public extension ServerCapabilities {
    func supports(personalDataSource sourceID: PersonalDataSourceID) -> Bool {
        features.contains(sourceID.capability)
    }
}
