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
