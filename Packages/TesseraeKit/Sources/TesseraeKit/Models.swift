import Foundation

public struct CompanionAPI: Codable, Hashable, Sendable {
    public let name: String
    public let version: Int

    public init(name: String = "companion", version: Int) {
        self.name = name
        self.version = version
    }
}

public struct PairingCapabilities: Codable, Hashable, Sendable {
    public let supported: Bool
    public let codeLength: Int
    public let ttlSeconds: Int

    public init(supported: Bool, codeLength: Int, ttlSeconds: Int) {
        self.supported = supported
        self.codeLength = codeLength
        self.ttlSeconds = ttlSeconds
    }
}

public struct CompanionLimits: Codable, Hashable, Sendable {
    public let imageUploadBytes: Int
    public let imageMaxEdge: Int
    public let imageContentTypes: [String]
    public let imageFitModes: [ImageFitMode]
    public let jobRetentionSeconds: Int
    public let idempotencyRetentionSeconds: Int

    public init(
        imageUploadBytes: Int,
        imageMaxEdge: Int,
        imageContentTypes: [String],
        imageFitModes: [ImageFitMode] = ImageFitMode.legacyModes,
        jobRetentionSeconds: Int,
        idempotencyRetentionSeconds: Int
    ) {
        self.imageUploadBytes = imageUploadBytes
        self.imageMaxEdge = imageMaxEdge
        self.imageContentTypes = imageContentTypes
        self.imageFitModes = imageFitModes
        self.jobRetentionSeconds = jobRetentionSeconds
        self.idempotencyRetentionSeconds = idempotencyRetentionSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case imageUploadBytes
        case imageMaxEdge
        case imageContentTypes
        case imageFitModes
        case jobRetentionSeconds
        case idempotencyRetentionSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        imageUploadBytes = try container.decode(Int.self, forKey: .imageUploadBytes)
        imageMaxEdge = try container.decode(Int.self, forKey: .imageMaxEdge)
        imageContentTypes = try container.decode(
            [String].self,
            forKey: .imageContentTypes
        )
        imageFitModes = try container.decodeIfPresent(
            [ImageFitMode].self,
            forKey: .imageFitModes
        ) ?? ImageFitMode.legacyModes
        jobRetentionSeconds = try container.decode(
            Int.self,
            forKey: .jobRetentionSeconds
        )
        idempotencyRetentionSeconds = try container.decode(
            Int.self,
            forKey: .idempotencyRetentionSeconds
        )
    }
}

public struct ServerCapabilities: Codable, Hashable, Sendable {
    public let product: String
    public let serverVersion: String
    public let api: CompanionAPI
    public let pairing: PairingCapabilities
    public let features: Set<String>
    public let limits: CompanionLimits
    public let webURL: String

    public init(
        product: String,
        serverVersion: String,
        api: CompanionAPI,
        pairing: PairingCapabilities,
        features: Set<String>,
        limits: CompanionLimits,
        webURL: String
    ) {
        self.product = product
        self.serverVersion = serverVersion
        self.api = api
        self.pairing = pairing
        self.features = features
        self.limits = limits
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case product
        case serverVersion
        case api
        case pairing
        case features
        case limits
        case webURL = "webUrl"
    }
}

public struct TesseraeInstance: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: URL
    public let serverVersion: String
    public let timezone: String
    public let webURL: String

    public init(
        id: String,
        name: String,
        baseURL: URL,
        serverVersion: String,
        timezone: String,
        webURL: String
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.serverVersion = serverVersion
        self.timezone = timezone
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case baseURL = "baseUrl"
        case serverVersion
        case timezone
        case webURL = "webUrl"
    }
}

public extension TesseraeInstance {
    func updatingServerVersion(to serverVersion: String) -> TesseraeInstance {
        TesseraeInstance(
            id: id,
            name: name,
            baseURL: baseURL,
            serverVersion: serverVersion,
            timezone: timezone,
            webURL: webURL
        )
    }
}

public struct PairingClient: Codable, Hashable, Sendable {
    public let name: String
    public let platform: String
    public let appVersion: String
    public let installationID: String

    public init(
        name: String,
        platform: String = "ios",
        appVersion: String,
        installationID: String
    ) {
        self.name = name
        self.platform = platform
        self.appVersion = appVersion
        self.installationID = installationID
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case platform
        case appVersion
        case installationID = "installationId"
    }
}

public struct PairingRequest: Codable, Hashable, Sendable {
    public let code: String
    public let client: PairingClient

    public init(code: String, client: PairingClient) {
        self.code = code
        self.client = client
    }
}

public struct InstanceDescriptor: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let serverVersion: String
    public let timezone: String
    public let webURL: String

    public init(
        id: String,
        name: String,
        serverVersion: String,
        timezone: String,
        webURL: String
    ) {
        self.id = id
        self.name = name
        self.serverVersion = serverVersion
        self.timezone = timezone
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case serverVersion
        case timezone
        case webURL = "webUrl"
    }
}

public struct PairingResponse: Codable, Hashable, Sendable {
    public let token: String
    public let tokenID: String
    public let scopes: [String]
    public let createdAt: Date
    public let instance: InstanceDescriptor

    public init(
        token: String,
        tokenID: String,
        scopes: [String],
        createdAt: Date,
        instance: InstanceDescriptor
    ) {
        self.token = token
        self.tokenID = tokenID
        self.scopes = scopes
        self.createdAt = createdAt
        self.instance = instance
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case tokenID = "tokenId"
        case scopes
        case createdAt
        case instance
    }
}

public struct PairedSession: Codable, Hashable, Sendable {
    public let instance: TesseraeInstance
    public let token: String
    public let tokenID: String
    public let scopes: [String]
    public let createdAt: Date

    public init(
        instance: TesseraeInstance,
        token: String,
        tokenID: String,
        scopes: [String],
        createdAt: Date
    ) {
        self.instance = instance
        self.token = token
        self.tokenID = tokenID
        self.scopes = scopes
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case instance
        case token
        case tokenID = "tokenId"
        case scopes
        case createdAt
    }
}

public struct PanelProfile: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int
    public let gamut: String
    public let orientation: String

    public init(width: Int, height: Int, gamut: String, orientation: String) {
        self.width = width
        self.height = height
        self.gamut = gamut
        self.orientation = orientation
    }
}

public enum DisplayFreshness: String, Codable, Hashable, Sendable {
    case fresh
    case stale
    case unknown
}

public struct DisplaySummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let panel: PanelProfile
    public let freshness: DisplayFreshness
    public let lastSeenAt: Date?
    public let batteryPercent: Int?
    public let rssiDBM: Int?
    public let firmwareVersion: String?

    public init(
        id: String,
        name: String,
        kind: String,
        panel: PanelProfile,
        freshness: DisplayFreshness,
        lastSeenAt: Date? = nil,
        batteryPercent: Int? = nil,
        rssiDBM: Int? = nil,
        firmwareVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.panel = panel
        self.freshness = freshness
        self.lastSeenAt = lastSeenAt
        self.batteryPercent = batteryPercent
        self.rssiDBM = rssiDBM
        self.firmwareVersion = firmwareVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case panel
        case freshness
        case lastSeenAt
        case batteryPercent
        case rssiDBM = "rssiDbm"
        case firmwareVersion
    }
}

public struct DevicesResponse: Codable, Hashable, Sendable {
    public let devices: [DisplaySummary]

    public init(devices: [DisplaySummary]) {
        self.devices = devices
    }
}

public enum DashboardKind: String, Codable, Hashable, Sendable {
    case grid
    case canvas
}

public struct DashboardSummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: DashboardKind
    public let deviceIDs: [String]
    public let updatedAt: Date?
    public let webURL: String?

    public init(
        id: String,
        name: String,
        kind: DashboardKind,
        deviceIDs: [String],
        updatedAt: Date? = nil,
        webURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.deviceIDs = deviceIDs
        self.updatedAt = updatedAt
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case deviceIDs = "deviceIds"
        case updatedAt
        case webURL = "webUrl"
    }
}

public struct DashboardsResponse: Codable, Hashable, Sendable {
    public let dashboards: [DashboardSummary]

    public init(dashboards: [DashboardSummary]) {
        self.dashboards = dashboards
    }
}

public enum ImageFitMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fit
    case fill
    case blur
    case stretch
    case center

    public static let legacyModes: [ImageFitMode] = [.fit, .fill]

    public var displayName: String {
        switch self {
        case .fit: "Fit"
        case .fill: "Fill"
        case .blur: "Blur"
        case .stretch: "Stretch"
        case .center: "Center"
        }
    }

    public var helpText: String {
        switch self {
        case .fit:
            "Show the whole image with space around it."
        case .fill:
            "Fill the display and crop the edges."
        case .blur:
            "Show the whole image over a blurred edge-to-edge background."
        case .stretch:
            "Stretch the image to the display, changing its proportions."
        case .center:
            "Keep the image at its prepared pixel size and clip or pad around it."
        }
    }
}

public struct DashboardPushRequest: Codable, Hashable, Sendable {
    public let deviceIDs: [String]?
    public let overrideQuietHours: Bool

    public init(deviceIDs: [String]? = nil, overrideQuietHours: Bool = false) {
        self.deviceIDs = deviceIDs
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIDs = "deviceIds"
        case overrideQuietHours
    }
}

public struct ImagePushRequest: Codable, Hashable, Sendable {
    public let deviceIDs: [String]
    public let fit: ImageFitMode
    public let overrideQuietHours: Bool

    public init(
        deviceIDs: [String],
        fit: ImageFitMode,
        overrideQuietHours: Bool = false
    ) {
        self.deviceIDs = deviceIDs
        self.fit = fit
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIDs = "deviceIds"
        case fit
        case overrideQuietHours
    }
}

public struct ImageURLPushRequest: Codable, Hashable, Sendable {
    public let url: URL
    public let deviceIDs: [String]
    public let fit: ImageFitMode
    public let overrideQuietHours: Bool

    public init(
        url: URL,
        deviceIDs: [String],
        fit: ImageFitMode,
        overrideQuietHours: Bool = false
    ) {
        self.url = url
        self.deviceIDs = deviceIDs
        self.fit = fit
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case deviceIDs = "deviceIds"
        case fit
        case overrideQuietHours
    }
}

public struct WebpagePushRequest: Codable, Hashable, Sendable {
    public let url: URL
    public let deviceIDs: [String]
    public let fit: ImageFitMode
    public let viewportW: Int?
    public let overrideQuietHours: Bool

    public init(
        url: URL,
        deviceIDs: [String],
        fit: ImageFitMode,
        viewportW: Int? = nil,
        overrideQuietHours: Bool = false
    ) {
        self.url = url
        self.deviceIDs = deviceIDs
        self.fit = fit
        self.viewportW = viewportW
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case url
        case deviceIDs = "deviceIds"
        case fit
        case viewportW
        case overrideQuietHours
    }
}

public struct HistoryResponse: Codable, Hashable, Sendable {
    public let items: [HistoryItem]
    public let nextBeforeID: String?

    public init(items: [HistoryItem], nextBeforeID: String?) {
        self.items = items
        self.nextBeforeID = nextBeforeID
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case nextBeforeID = "nextBeforeId"
    }
}

public struct HistoryItem: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let createdAt: Date
    public let source: String
    public let label: String
    public let deviceIDs: [String]
    public let status: String
    public let durationSeconds: Double?
    public let error: String?
    public let previewAvailable: Bool
    public let resendable: Bool
    public let fit: ImageFitMode?

    public init(
        id: String,
        createdAt: Date,
        source: String,
        label: String,
        deviceIDs: [String],
        status: String,
        durationSeconds: Double? = nil,
        error: String? = nil,
        previewAvailable: Bool,
        resendable: Bool,
        fit: ImageFitMode? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.source = source
        self.label = label
        self.deviceIDs = deviceIDs
        self.status = status
        self.durationSeconds = durationSeconds
        self.error = error
        self.previewAvailable = previewAvailable
        self.resendable = resendable
        self.fit = fit
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case createdAt
        case source
        case label
        case deviceIDs = "deviceIds"
        case status
        case durationSeconds
        case error
        case previewAvailable
        case resendable
        case fit
    }
}

public struct HistoryResendRequest: Codable, Hashable, Sendable {
    public let overrideQuietHours: Bool

    public init(overrideQuietHours: Bool = false) {
        self.overrideQuietHours = overrideQuietHours
    }
}

public enum PushJobKind: String, Codable, Hashable, Sendable {
    case dashboardPush = "dashboard_push"
    case imagePush = "image_push"
    case imageURLPush = "image_url_push"
    case webpagePush = "webpage_push"
    case historyResend = "history_resend"
}

public enum PushJobStatus: String, Codable, Hashable, Sendable {
    case accepted
    case running
    case succeeded
    case failed
}

public enum PushOutcomeStatus: String, Codable, Hashable, Sendable {
    case published
    case quiet
}

public struct PushJobResult: Codable, Hashable, Sendable {
    public let status: PushOutcomeStatus
    public let reason: String?
    public let deviceIDs: [String]
    public let historyEventIDs: [String]?

    public init(
        status: PushOutcomeStatus,
        reason: String? = nil,
        deviceIDs: [String],
        historyEventIDs: [String]? = nil
    ) {
        self.status = status
        self.reason = reason
        self.deviceIDs = deviceIDs
        self.historyEventIDs = historyEventIDs
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case reason
        case deviceIDs = "deviceIds"
        case historyEventIDs = "historyEventIds"
    }
}

public struct PushJobFailure: Codable, Hashable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PushJob: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let kind: PushJobKind
    public let status: PushJobStatus
    public let label: String?
    public let targetDeviceIDs: [String]
    public let createdAt: Date
    public let updatedAt: Date
    public let result: PushJobResult?
    public let error: PushJobFailure?

    public init(
        id: String,
        kind: PushJobKind,
        status: PushJobStatus,
        label: String? = nil,
        targetDeviceIDs: [String],
        createdAt: Date,
        updatedAt: Date,
        result: PushJobResult? = nil,
        error: PushJobFailure? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.label = label
        self.targetDeviceIDs = targetDeviceIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.result = result
        self.error = error
    }

    public var isTerminal: Bool {
        status == .succeeded || status == .failed
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case status
        case label
        case targetDeviceIDs = "targetDeviceIds"
        case createdAt
        case updatedAt
        case result
        case error
    }
}

public struct JobResponse: Codable, Hashable, Sendable {
    public let job: PushJob

    public init(job: PushJob) {
        self.job = job
    }
}

public struct APIErrorBody: Codable, Hashable, Sendable {
    public let code: String
    public let message: String
    public let requestID: String?

    public init(code: String, message: String, requestID: String? = nil) {
        self.code = code
        self.message = message
        self.requestID = requestID
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "requestId"
    }
}

public struct APIErrorResponse: Codable, Hashable, Sendable {
    public let error: APIErrorBody

    public init(error: APIErrorBody) {
        self.error = error
    }
}
