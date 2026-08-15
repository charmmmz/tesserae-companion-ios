import Foundation

public enum LineupIntent: String, Codable, Hashable, Sendable {
    case daily
    case interval
    case cycle
    case manual
}

public enum LineupAdvance: String, Codable, Hashable, Sendable {
    case manual
    case timer
    case both
}

public enum LineupTrigger: String, Codable, Hashable, Sendable {
    case cycle
    case interval
    case daily
}

public enum LineupMode: String, Codable, Hashable, Sendable {
    case scheduled
    case priority
}

public enum LineupStateAction: String, Codable, Hashable, Sendable {
    case enable
    case disable
}

public enum LineupPaintAction: String, Codable, CaseIterable, Hashable, Sendable {
    case next
    case previous
    case play
}

public indirect enum LineupJSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([LineupJSONValue])
    case object([String: LineupJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([LineupJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: LineupJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }
}

public struct LineupCondition: Codable, Hashable, Sendable {
    public let sourceKind: String
    public let sourceID: String
    public let `operator`: String
    public let value: LineupJSONValue

    public init(
        sourceKind: String,
        sourceID: String,
        operator: String,
        value: LineupJSONValue
    ) {
        self.sourceKind = sourceKind
        self.sourceID = sourceID
        self.operator = `operator`
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case sourceKind
        case sourceID = "sourceId"
        case `operator`
        case value
    }
}

public struct LineupZone: Codable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case x, y
        case width = "w"
        case height = "h"
    }
}

public struct LineupLink: Codable, Hashable, Sendable {
    public let targetPageID: String
    public let button: String?
    public let zone: LineupZone?

    public init(targetPageID: String, button: String? = nil, zone: LineupZone? = nil) {
        self.targetPageID = targetPageID
        self.button = button
        self.zone = zone
    }

    private enum CodingKeys: String, CodingKey {
        case targetPageID = "targetPageId"
        case button
        case zone
    }
}

public struct LineupDashboard: Codable, Hashable, Sendable {
    public let pageID: String
    public let name: String
    public let dwellMinutes: Int
    public let missing: Bool
    public let refreshIntervalMinutes: Int?
    public let links: [LineupLink]?
    public let conditions: [LineupCondition]?

    private enum CodingKeys: String, CodingKey {
        case pageID = "pageId"
        case name
        case dwellMinutes
        case missing
        case refreshIntervalMinutes
        case links
        case conditions
    }
}

public struct LineupCurrent: Codable, Hashable, Sendable {
    public let deviceID: String
    public let pageID: String

    public init(deviceID: String, pageID: String) {
        self.deviceID = deviceID
        self.pageID = pageID
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case pageID = "pageId"
    }
}

public struct Lineup: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let intent: LineupIntent?
    public let deviceIDs: [String]
    // Added in Tesserae v0.295.0. Keep optional so snapshots and responses
    // from older servers remain readable; when absent, only the explicit
    // authored binding is safe to use for control.
    public let resolvedDeviceIDs: [String]?
    public let dashboards: [LineupDashboard]
    public let current: [LineupCurrent]
    public let nextAdvanceEpoch: Int64?
    public let advance: LineupAdvance
    public let trigger: LineupTrigger?
    public let intervalMinutes: Int?
    public let firesAt: String?
    public let anchor: String?

    // Additive 0.8 read fields. They stay optional in the client so the
    // v0.289.2 server projection remains readable while the contract additions
    // roll out; absence must never be interpreted as a safe authoring default.
    public let entryPageID: String?
    public let homePageID: String?
    public let homeTimeoutMinutes: Int?
    public let refreshIntervalMinutes: Int?
    public let endAt: String?
    public let daysOfWeek: [Int]?
    public let priority: Int?
    public let smartSync: Bool?
    public let smartSyncLeadSeconds: Int?
    public let mode: LineupMode?
    public let minHoldMinutes: Int?
    public let windowStart: String?
    public let windowEnd: String?
    public let fallbackPageID: String?

    public let nativeEditable: Bool
    public let requiresWebReason: String?
    public let webURL: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case enabled
        case intent
        case deviceIDs = "deviceIds"
        case resolvedDeviceIDs = "resolvedDeviceIds"
        case dashboards
        case current
        case nextAdvanceEpoch
        case advance
        case trigger
        case intervalMinutes
        case firesAt
        case anchor
        case entryPageID = "entryPageId"
        case homePageID = "homePageId"
        case homeTimeoutMinutes
        case refreshIntervalMinutes
        case endAt
        case daysOfWeek
        case priority
        case smartSync
        case smartSyncLeadSeconds
        case mode
        case minHoldMinutes
        case windowStart
        case windowEnd
        case fallbackPageID = "fallbackPageId"
        case nativeEditable
        case requiresWebReason
        case webURL = "webUrl"
    }
}

public struct LineupsResponse: Codable, Hashable, Sendable {
    public let lineups: [Lineup]
}

public struct LineupResponse: Codable, Hashable, Sendable {
    public let lineup: Lineup
}

public struct VersionedLineup: Hashable, Sendable {
    public let lineup: Lineup
    public let eTag: String

    public init(lineup: Lineup, eTag: String) {
        self.lineup = lineup
        self.eTag = eTag
    }
}

public struct CompanionSessionAuthorization: Codable, Hashable, Sendable {
    public let tokenID: String
    public let scopes: Set<String>
    public let settingsURL: String?

    public init(
        tokenID: String,
        scopes: Set<String>,
        settingsURL: String? = nil
    ) {
        self.tokenID = tokenID
        self.scopes = scopes
        self.settingsURL = settingsURL
    }

    public var canAuthorLineups: Bool {
        scopes.contains("lineups:write")
    }

    public var canWriteGallery: Bool {
        scopes.contains("gallery:write")
    }

    public var canWriteOfflineAlbums: Bool {
        scopes.contains("offline_albums:write")
    }

    private enum CodingKeys: String, CodingKey {
        case tokenID = "tokenId"
        case scopes
        case settingsURL = "settingsUrl"
    }
}

public struct LineupCreateRequest: Codable, Hashable, Sendable {
    public let intent: LineupIntent
    public let name: String
    public let pageIDs: [String]
    public let deviceIDs: [String]
    public let dwellMinutes: [String: Int]?
    public let intervalMinutes: Int?
    public let firesAt: String?
    public let anchor: String?
    public let bindUnassignedDashboards: Bool

    public init(
        intent: LineupIntent,
        name: String,
        pageIDs: [String],
        deviceIDs: [String],
        dwellMinutes: [String: Int]? = nil,
        intervalMinutes: Int? = nil,
        firesAt: String? = nil,
        anchor: String? = nil,
        bindUnassignedDashboards: Bool = false
    ) {
        self.intent = intent
        self.name = name
        self.pageIDs = pageIDs
        self.deviceIDs = deviceIDs
        self.dwellMinutes = dwellMinutes
        self.intervalMinutes = intervalMinutes
        self.firesAt = firesAt
        self.anchor = anchor
        self.bindUnassignedDashboards = bindUnassignedDashboards
    }

    private enum CodingKeys: String, CodingKey {
        case intent
        case name
        case pageIDs = "pageIds"
        case deviceIDs = "deviceIds"
        case dwellMinutes
        case intervalMinutes
        case firesAt
        case anchor
        case bindUnassignedDashboards
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(intent, forKey: .intent)
        try container.encode(name, forKey: .name)
        try container.encode(pageIDs, forKey: .pageIDs)
        if !deviceIDs.isEmpty {
            try container.encode(deviceIDs, forKey: .deviceIDs)
        }
        try container.encodeIfPresent(dwellMinutes, forKey: .dwellMinutes)
        try container.encodeIfPresent(intervalMinutes, forKey: .intervalMinutes)
        try container.encodeIfPresent(firesAt, forKey: .firesAt)
        try container.encodeIfPresent(anchor, forKey: .anchor)
        try container.encode(
            bindUnassignedDashboards,
            forKey: .bindUnassignedDashboards
        )
    }
}

public struct LineupPatchRequest: Codable, Hashable, Sendable {
    public let name: String?
    public let enabled: Bool?
    public let deviceIDs: [String]?
    public let pageIDs: [String]?
    public let dwellMinutes: [String: Int]?
    public let intervalMinutes: Int?
    public let firesAt: String?
    public let anchor: String?

    public init(
        name: String? = nil,
        enabled: Bool? = nil,
        deviceIDs: [String]? = nil,
        pageIDs: [String]? = nil,
        dwellMinutes: [String: Int]? = nil,
        intervalMinutes: Int? = nil,
        firesAt: String? = nil,
        anchor: String? = nil
    ) {
        self.name = name
        self.enabled = enabled
        self.deviceIDs = deviceIDs
        self.pageIDs = pageIDs
        self.dwellMinutes = dwellMinutes
        self.intervalMinutes = intervalMinutes
        self.firesAt = firesAt
        self.anchor = anchor
    }

    public var isEmpty: Bool {
        name == nil
            && enabled == nil
            && deviceIDs == nil
            && pageIDs == nil
            && dwellMinutes == nil
            && intervalMinutes == nil
            && firesAt == nil
            && anchor == nil
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case enabled
        case deviceIDs = "deviceIds"
        case pageIDs = "pageIds"
        case dwellMinutes
        case intervalMinutes
        case firesAt
        case anchor
    }
}

public struct LineupStateActionRequest: Codable, Hashable, Sendable {
    public let action: LineupStateAction

    public init(action: LineupStateAction) {
        self.action = action
    }
}

public struct LineupPaintActionRequest: Codable, Hashable, Sendable {
    public let action: LineupPaintAction
    public let pageID: String?
    public let deviceIDs: [String]?
    public let overrideQuietHours: Bool

    public init(
        action: LineupPaintAction,
        pageID: String? = nil,
        deviceIDs: [String]? = nil,
        overrideQuietHours: Bool = false
    ) {
        self.action = action
        self.pageID = pageID
        self.deviceIDs = deviceIDs
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case action
        case pageID = "pageId"
        case deviceIDs = "deviceIds"
        case overrideQuietHours
    }
}
