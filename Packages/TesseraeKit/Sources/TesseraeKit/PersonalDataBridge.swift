import Foundation

public enum PersonalDataSourceID: String, Codable, CaseIterable, Hashable, Sendable {
    case reminders
    case remindersFridge = "reminders.fridge"
    case healthSummary = "health.summary"
}

public struct PersonalDataCapabilities: Codable, Hashable, Sendable {
    /// Raw source ids stay forward-compatible when a newer server advertises
    /// Calendar, Health, or another schema this app version does not know yet.
    public let sources: Set<String>

    public init(sources: Set<String>) {
        self.sources = sources
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

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case dueDate
        case priority
        case completed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        if let dueDate {
            try container.encode(dueDate, forKey: .dueDate)
        } else {
            try container.encodeNil(forKey: .dueDate)
        }
        try container.encode(priority, forKey: .priority)
        try container.encode(completed, forKey: .completed)
    }
}

public struct ReminderListSnapshot: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let items: [ReminderSnapshotItem]

    public init(id: String, title: String, items: [ReminderSnapshotItem]) {
        self.id = id
        self.title = title
        self.items = items
    }
}

public struct RemindersData: Codable, Hashable, Sendable {
    public let lists: [ReminderListSnapshot]

    public init(lists: [ReminderListSnapshot]) {
        self.lists = lists
    }
}

public struct RemindersSnapshot: Codable, Hashable, Sendable {
    public let version: PersonalDataSnapshotVersion
    public let sourceID: PersonalDataSourceID
    public let generatedAt: Date
    public let expiresAt: Date
    public let data: RemindersData

    public init(
        version: PersonalDataSnapshotVersion = .v1,
        sourceID: PersonalDataSourceID = .reminders,
        generatedAt: Date,
        expiresAt: Date,
        data: RemindersData
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
        personalData?.sources.contains(sourceID.rawValue) == true
    }

    /// Apple Health is a separate consent boundary and requires both the
    /// dedicated feature and strict source advertisement.
    var supportsHealthSummary: Bool {
        features.contains("personal_data_health")
            && supports(personalDataSource: .healthSummary)
    }
}
