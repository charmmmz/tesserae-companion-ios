import Foundation

public struct CloudBootstrap: Decodable, Sendable {
    public let account: CloudAccount
    public let devices: [CloudDevice]
    public let pages: [CloudPage]

    public init(account: CloudAccount, devices: [CloudDevice], pages: [CloudPage]) {
        self.account = account
        self.devices = devices
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey { case account = "me", devices, pages }
}

public struct CloudAccount: Decodable, Sendable {
    public struct User: Decodable, Sendable {
        public let id: String
        public let email: String
    }

    public struct Tenant: Decodable, Sendable {
        public let id: String
        public let name: String
    }

    public struct Authorization: Decodable, Sendable {
        public let resource: String
        public let scopes: [String]
        public let grantID: String
        public let generation: Int

        enum CodingKeys: String, CodingKey {
            case resource, scopes, grantID = "grant_id", generation
        }
    }

    public let id: String
    public let name: String
    public let role: String
    public let user: User
    public let tenant: Tenant
    public let issuer: URL
    public let auth: Authorization
    public let features: [String: Bool]
    public let limits: [String: Double?]
    public let usage: CloudUsage
}

public struct CloudUsage: Decodable, Sendable {
    public let rendersToday: Int
    public let rendersChargedToday: Int
    public let mcpCallsToday: Int
    public let browserMillisecondsToday: Double
    public let devices: Int
    public let pages: Int
    public let storageBytes: Double

    enum CodingKeys: String, CodingKey {
        case rendersToday = "renders_today", rendersChargedToday = "renders_charged_today"
        case mcpCallsToday = "mcp_calls_today", browserMillisecondsToday = "browser_ms_today"
        case devices, pages, storageBytes = "storage_bytes"
    }
}

public struct CloudDevice: Decodable, Sendable, Identifiable {
    public struct Panel: Decodable, Sendable {
        public let width: Int
        public let height: Int
        public let nativeWidth: Int?
        public let nativeHeight: Int?
        public let gamut: String?
        public let underscan: Int?

        public var compositionGeometry: CloudCompositionGeometry? {
            let inset = underscan ?? 0
            guard inset >= 0, inset <= min(width, height) / 2 else { return nil }
            return try? .init(width: width - 2 * inset, height: height - 2 * inset)
        }

        enum CodingKeys: String, CodingKey {
            case width = "w", height = "h", nativeWidth = "native_w", nativeHeight = "native_h", gamut, underscan
        }
    }

    public struct Frame: Decodable, Sendable {
        public let digest: String
        public let bytes: Int
        public let renderedAt: Date
        public let pageID: String?

        enum CodingKeys: String, CodingKey {
            case digest, bytes, renderedAt = "rendered_at", pageID = "page_id"
        }
    }

    public let id: String
    public let name: String
    public let kind: String
    public let firmwareVersion: String?
    public let panel: Panel
    public let format: String
    public let dither: String
    public let sleepInterval: Int
    public let pageID: String?
    public let lineupID: String?
    public let pausedAt: Date?
    public let lastSeenAt: Date?
    public let batteryPercent: Double?
    public let rssi: Double?
    public let frame: Frame?
    public let staleSince: Date?
    public let nextDueAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, kind, panel, format, dither, rssi, frame
        case firmwareVersion = "fw_version", sleepInterval = "sleep_interval_s"
        case pageID = "page_id", lineupID = "lineup_id", pausedAt = "paused_at"
        case lastSeenAt = "last_seen_at", batteryPercent = "battery_pct"
        case staleSince = "stale_since", nextDueAt = "next_due_at"
    }
}

public struct CloudPage: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let deviceID: String?
    public let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, kind, deviceID = "device_id", updatedAt = "updated_at"
    }
}

public enum CloudReadError: Error, Equatable, Sendable {
    case unauthorized
    case forbidden(reason: String?)
    case limitReached
    case retryLater(retryAfter: TimeInterval?)
    case unavailable
    case notFound
    case invalidResponse
    case unexpectedStatus(Int)
}
