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
    public let imageFramingMaxZoom: Double?
    public let galleryUploadBytes: Int?
    public let galleryImageContentTypes: [String]?
    public let galleryUploadBatchSize: Int?
    public let personalDataStaleAfterSeconds: Int?
    public let personalDataMaxTTLSeconds: Int?
    public let jobRetentionSeconds: Int
    public let idempotencyRetentionSeconds: Int

    public init(
        imageUploadBytes: Int,
        imageMaxEdge: Int,
        imageContentTypes: [String],
        imageFitModes: [ImageFitMode] = ImageFitMode.legacyModes,
        imageFramingMaxZoom: Double? = nil,
        galleryUploadBytes: Int? = nil,
        galleryImageContentTypes: [String]? = nil,
        galleryUploadBatchSize: Int? = nil,
        personalDataStaleAfterSeconds: Int? = nil,
        personalDataMaxTTLSeconds: Int? = nil,
        jobRetentionSeconds: Int,
        idempotencyRetentionSeconds: Int
    ) {
        self.imageUploadBytes = imageUploadBytes
        self.imageMaxEdge = imageMaxEdge
        self.imageContentTypes = imageContentTypes
        self.imageFitModes = imageFitModes
        self.imageFramingMaxZoom = imageFramingMaxZoom
        self.galleryUploadBytes = galleryUploadBytes
        self.galleryImageContentTypes = galleryImageContentTypes
        self.galleryUploadBatchSize = galleryUploadBatchSize
        self.personalDataStaleAfterSeconds = personalDataStaleAfterSeconds
        self.personalDataMaxTTLSeconds = personalDataMaxTTLSeconds
        self.jobRetentionSeconds = jobRetentionSeconds
        self.idempotencyRetentionSeconds = idempotencyRetentionSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case imageUploadBytes
        case imageMaxEdge
        case imageContentTypes
        case imageFitModes
        case imageFramingMaxZoom
        case galleryUploadBytes
        case galleryImageContentTypes
        case galleryUploadBatchSize
        case personalDataStaleAfterSeconds
        case personalDataMaxTTLSeconds = "personalDataMaxTtlSeconds"
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
        imageFramingMaxZoom = try container.decodeIfPresent(
            Double.self,
            forKey: .imageFramingMaxZoom
        )
        galleryUploadBytes = try container.decodeIfPresent(
            Int.self,
            forKey: .galleryUploadBytes
        )
        galleryImageContentTypes = try container.decodeIfPresent(
            [String].self,
            forKey: .galleryImageContentTypes
        )
        galleryUploadBatchSize = try container.decodeIfPresent(
            Int.self,
            forKey: .galleryUploadBatchSize
        )
        personalDataStaleAfterSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .personalDataStaleAfterSeconds
        )
        personalDataMaxTTLSeconds = try container.decodeIfPresent(
            Int.self,
            forKey: .personalDataMaxTTLSeconds
        )
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
    public let personalData: PersonalDataCapabilities?
    public let limits: CompanionLimits
    public let webURL: String

    public init(
        product: String,
        serverVersion: String,
        api: CompanionAPI,
        pairing: PairingCapabilities,
        features: Set<String>,
        personalData: PersonalDataCapabilities? = nil,
        limits: CompanionLimits,
        webURL: String
    ) {
        self.product = product
        self.serverVersion = serverVersion
        self.api = api
        self.pairing = pairing
        self.features = features
        self.personalData = personalData
        self.limits = limits
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case product
        case serverVersion
        case api
        case pairing
        case features
        case personalData
        case limits
        case webURL = "webUrl"
    }

    public func supports(_ linkPushKind: LinkPushKind) -> Bool {
        features.contains(linkPushKind.capability)
    }

    public var supportsImageFraming: Bool {
        features.contains("image_framing")
            && (limits.imageFramingMaxZoom ?? 0) >= 1
    }

    public var supportsGallery: Bool {
        features.contains("gallery")
    }

    public var supportsOfflineAlbums: Bool {
        features.contains("offline_albums")
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

public enum DeviceCapabilitySupportState: String, Codable, Hashable, Sendable {
    case supported
    case unsupported
    case unknown
}

public struct DeviceCapabilitySupport: Codable, Hashable, Sendable {
    public let state: DeviceCapabilitySupportState
    public let reasonCode: String?
    public let observedAt: Date?
    public let detail: [String: Int]?

    public init(
        state: DeviceCapabilitySupportState,
        reasonCode: String? = nil,
        observedAt: Date? = nil,
        detail: [String: Int]? = nil
    ) {
        self.state = state
        self.reasonCode = reasonCode
        self.observedAt = observedAt
        self.detail = detail
    }

    public var frameCacheCapacityBytes: Int? {
        detail?["capacity_bytes"]
    }

    public var frameCacheMaxFrames: Int? {
        detail?["max_frames"]
    }
}

public struct PendingRender: Codable, Hashable, Sendable {
    public let revision: String
    public let renderedAt: Date?
    public let previewURL: String

    public init(
        revision: String,
        renderedAt: Date? = nil,
        previewURL: String
    ) {
        self.revision = revision
        self.renderedAt = renderedAt
        self.previewURL = previewURL
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case renderedAt
        case previewURL = "previewUrl"
    }
}

public struct DisplaySummary: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let iconName: String
    public let panel: PanelProfile
    public let freshness: DisplayFreshness
    public let lastSeenAt: Date?
    public let batteryPercent: Int?
    public let rssiDBM: Int?
    public let firmwareVersion: String?
    public let capabilitySupport: [String: DeviceCapabilitySupport]?
    public let hasPendingRender: Bool?
    public let pendingRender: PendingRender?

    public init(
        id: String,
        name: String,
        kind: String,
        iconName: String,
        panel: PanelProfile,
        freshness: DisplayFreshness,
        lastSeenAt: Date? = nil,
        batteryPercent: Int? = nil,
        rssiDBM: Int? = nil,
        firmwareVersion: String? = nil,
        capabilitySupport: [String: DeviceCapabilitySupport]? = nil,
        hasPendingRender: Bool? = nil,
        pendingRender: PendingRender? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconName = iconName
        self.panel = panel
        self.freshness = freshness
        self.lastSeenAt = lastSeenAt
        self.batteryPercent = batteryPercent
        self.rssiDBM = rssiDBM
        self.firmwareVersion = firmwareVersion
        self.capabilitySupport = capabilitySupport
        self.hasPendingRender = hasPendingRender
        self.pendingRender = pendingRender
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case iconName = "icon"
        case panel
        case freshness
        case lastSeenAt
        case batteryPercent
        case rssiDBM = "rssiDbm"
        case firmwareVersion
        case capabilitySupport
        case hasPendingRender
        case pendingRender
    }

    public var frameCacheSupport: DeviceCapabilitySupport? {
        capabilitySupport?["frame_cache"]
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
    public let iconName: String?
    public let deviceIDs: [String]
    public let updatedAt: Date?
    public let webURL: String?

    public init(
        id: String,
        name: String,
        kind: DashboardKind,
        iconName: String? = nil,
        deviceIDs: [String],
        updatedAt: Date? = nil,
        webURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.iconName = iconName
        self.deviceIDs = deviceIDs
        self.updatedAt = updatedAt
        self.webURL = webURL
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case kind
        case iconName = "icon"
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

public struct ImageFraming: Codable, Hashable, Sendable {
    /// Horizontal subject focus in the orientation-normalized source image.
    public let focusX: Double
    /// Vertical subject focus in the orientation-normalized source image.
    public let focusY: Double
    /// Scale relative to ordinary Fill, bounded by the advertised server limit.
    public let zoom: Double

    public init(focusX: Double, focusY: Double, zoom: Double) {
        self.focusX = focusX
        self.focusY = focusY
        self.zoom = zoom
    }

    /// Resolves the normalized source crop described by the Companion 0.6
    /// contract for one target panel. Source dimensions must describe the
    /// orientation-normalized image. The server performs the same operation
    /// before its existing Fill path and owns final pixel rounding.
    public func resolvedCrop(
        sourceWidth: Double,
        sourceHeight: Double,
        targetWidth: Double,
        targetHeight: Double
    ) -> NormalizedImageCrop {
        guard
            sourceWidth > 0,
            sourceHeight > 0,
            targetWidth > 0,
            targetHeight > 0
        else {
            return .full
        }

        let sourceAspect = sourceWidth / sourceHeight
        let targetAspect = targetWidth / targetHeight
        let baseWidth: Double
        let baseHeight: Double
        if sourceAspect >= targetAspect {
            baseWidth = targetAspect / sourceAspect
            baseHeight = 1
        } else {
            baseWidth = 1
            baseHeight = sourceAspect / targetAspect
        }

        let safeZoom = max(zoom, 1)
        let width = baseWidth / safeZoom
        let height = baseHeight / safeZoom
        let safeFocusX = min(max(focusX, 0), 1)
        let safeFocusY = min(max(focusY, 0), 1)
        let x = min(max(safeFocusX - width / 2, 0), 1 - width)
        let y = min(max(safeFocusY - height / 2, 0), 1 - height)
        return NormalizedImageCrop(x: x, y: y, width: width, height: height)
    }
}

public struct NormalizedImageCrop: Equatable, Hashable, Sendable {
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

    public static let full = NormalizedImageCrop(
        x: 0,
        y: 0,
        width: 1,
        height: 1
    )
}

public enum LinkPushKind: String, Codable, CaseIterable, Hashable, Sendable {
    case imageURL = "image_url"
    case webpage

    public var capability: String {
        switch self {
        case .imageURL:
            "image_url_push"
        case .webpage:
            "webpage_push"
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
    public let framing: ImageFraming?
    public let overrideQuietHours: Bool

    public init(
        deviceIDs: [String],
        fit: ImageFitMode,
        framing: ImageFraming? = nil,
        overrideQuietHours: Bool = false
    ) {
        self.deviceIDs = deviceIDs
        self.fit = fit
        self.framing = framing
        self.overrideQuietHours = overrideQuietHours
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIDs = "deviceIds"
        case fit
        case framing
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
    public let framing: ImageFraming?

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
        fit: ImageFitMode? = nil,
        framing: ImageFraming? = nil
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
        self.framing = framing
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
        case framing
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
    case lineupAction = "lineup_action"
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
    public let claims: [String: OfflineAlbumConflictClaim]?
    public let deviceIDs: [String]?

    public init(
        code: String,
        message: String,
        requestID: String? = nil,
        claims: [String: OfflineAlbumConflictClaim]? = nil,
        deviceIDs: [String]? = nil
    ) {
        self.code = code
        self.message = message
        self.requestID = requestID
        self.claims = claims
        self.deviceIDs = deviceIDs
    }

    private enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestID = "requestId"
        case claims
        case deviceIDs = "deviceIds"
    }
}

public struct APIErrorResponse: Codable, Hashable, Sendable {
    public let error: APIErrorBody

    public init(error: APIErrorBody) {
        self.error = error
    }
}
