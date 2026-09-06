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

/// Retention is chosen independently for each source and server. A nil
/// deadline is sent only after the server advertises personal_data_retention.
public enum PersonalDataRetention: Int, Codable, CaseIterable, Sendable {
    case oneDay = 86400
    case twoDays = 172800
    case sevenDays = 604800
    case thirtyDays = 2592000
    case ninetyDays = 7776000
    case never = 0

    public func isSupported(maximumTTLSeconds: Int?, allowsNever: Bool) -> Bool {
        if self == .never { return allowsNever }
        return rawValue <= (maximumTTLSeconds ?? Self.twoDays.rawValue)
    }

    public func expirationDate(from generatedAt: Date, maximumTTLSeconds: Int?) -> Date? {
        guard self != .never else { return nil }
        return generatedAt.addingTimeInterval(TimeInterval(
            max(1, min(rawValue, maximumTTLSeconds ?? Self.twoDays.rawValue))
        ))
    }
}

public struct RemindersSnapshot: Codable, Hashable, Sendable {
    public let version: PersonalDataSnapshotVersion
    public let sourceID: PersonalDataSourceID
    public let generatedAt: Date
    public let expiresAt: Date?
    public let data: RemindersData

    public init(
        version: PersonalDataSnapshotVersion = .v1,
        sourceID: PersonalDataSourceID = .reminders,
        generatedAt: Date,
        expiresAt: Date?,
        data: RemindersData
    ) {
        self.version = version
        self.sourceID = sourceID
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.data = data
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(expiresAt, forKey: .expiresAt)
        try container.encode(data, forKey: .data)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(PersonalDataSnapshotVersion.self, forKey: .version)
        sourceID = try container.decode(PersonalDataSourceID.self, forKey: .sourceID)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        expiresAt = try container.decode(Date?.self, forKey: .expiresAt)
        data = try container.decode(RemindersData.self, forKey: .data)
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
    public let expiresAt: Date?

    public init(
        sourceID: PersonalDataSourceID,
        state: PersonalDataFreshness,
        generatedAt: Date,
        staleAt: Date,
        expiresAt: Date?
    ) {
        self.sourceID = sourceID
        self.state = state
        self.generatedAt = generatedAt
        self.staleAt = staleAt
        self.expiresAt = expiresAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try container.decode(PersonalDataSourceID.self, forKey: .sourceID)
        state = try container.decode(PersonalDataFreshness.self, forKey: .state)
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        staleAt = try container.decode(Date.self, forKey: .staleAt)
        expiresAt = try container.decode(Date?.self, forKey: .expiresAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(state, forKey: .state)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(staleAt, forKey: .staleAt)
        try container.encode(expiresAt, forKey: .expiresAt)
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
