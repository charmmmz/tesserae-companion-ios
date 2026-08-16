import Foundation

public enum OfflineAlbumFitMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fit
    case fill
}

public enum OfflineAlbumPlaybackMode: String, Codable, CaseIterable, Hashable, Sendable {
    case sequential
    case shuffle
}

public enum OfflineAlbumRepeatMode: String, Codable, CaseIterable, Hashable, Sendable {
    case loop
    case reshuffle
    case once
}

public struct OfflineAlbumPlayback: Codable, Hashable, Sendable {
    public let mode: OfflineAlbumPlaybackMode
    public let intervalSeconds: Int
    public let repeatMode: OfflineAlbumRepeatMode

    public init(
        mode: OfflineAlbumPlaybackMode,
        intervalSeconds: Int,
        repeatMode: OfflineAlbumRepeatMode
    ) {
        self.mode = mode
        self.intervalSeconds = intervalSeconds
        self.repeatMode = repeatMode
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case intervalSeconds = "intervalS"
        case repeatMode = "repeat"
    }
}

public struct OfflineAlbumDraft: Codable, Hashable, Sendable {
    public let name: String
    public let enabled: Bool
    public let deviceIDs: [String]
    public let order: [String]
    public let fit: OfflineAlbumFitMode
    public let playback: OfflineAlbumPlayback

    public init(
        name: String,
        enabled: Bool,
        deviceIDs: [String],
        order: [String],
        fit: OfflineAlbumFitMode,
        playback: OfflineAlbumPlayback
    ) {
        self.name = name
        self.enabled = enabled
        self.deviceIDs = deviceIDs
        self.order = order
        self.fit = fit
        self.playback = playback
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case enabled
        case deviceIDs = "deviceIds"
        case order
        case fit
        case playback
    }
}

public struct OfflineAlbumWriteRequest: Codable, Hashable, Sendable {
    public let album: OfflineAlbumDraft
    public let replaceConflicts: Bool

    public init(
        album: OfflineAlbumDraft,
        replaceConflicts: Bool = false
    ) {
        self.album = album
        self.replaceConflicts = replaceConflicts
    }
}

public struct OfflineAlbum: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let folderID: String
    public let name: String
    public let enabled: Bool
    public let deviceIDs: [String]
    public let order: [String]
    public let fit: OfflineAlbumFitMode
    public let playback: OfflineAlbumPlayback

    public init(
        id: String,
        folderID: String,
        name: String,
        enabled: Bool,
        deviceIDs: [String],
        order: [String],
        fit: OfflineAlbumFitMode,
        playback: OfflineAlbumPlayback
    ) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.enabled = enabled
        self.deviceIDs = deviceIDs
        self.order = order
        self.fit = fit
        self.playback = playback
    }

    public init(id: String, folderID: String, draft: OfflineAlbumDraft) {
        self.init(
            id: id,
            folderID: folderID,
            name: draft.name,
            enabled: draft.enabled,
            deviceIDs: draft.deviceIDs,
            order: draft.order,
            fit: draft.fit,
            playback: draft.playback
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case folderID = "folderId"
        case name
        case enabled
        case deviceIDs = "deviceIds"
        case order
        case fit
        case playback
    }
}

public struct OfflineAlbumConflictClaim: Codable, Hashable, Sendable {
    public let albumID: String
    public let name: String

    public init(albumID: String, name: String) {
        self.albumID = albumID
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case albumID = "albumId"
        case name
    }
}

public enum OfflineAlbumProjectionAccuracy: String, Codable, Hashable, Sendable {
    case exact
    case estimated
}

public struct OfflineAlbumStorageProjection: Codable, Hashable, Sendable {
    public let bytes: Int
    public let accuracy: OfflineAlbumProjectionAccuracy

    public init(bytes: Int, accuracy: OfflineAlbumProjectionAccuracy) {
        self.bytes = bytes
        self.accuracy = accuracy
    }
}

public struct OfflineAlbumPlan: Codable, Hashable, Sendable {
    public let totalFrames: Int
    public let cacheableFrames: Int
    public let accuracy: OfflineAlbumProjectionAccuracy
    public let fullyOffline: Bool
    public let storage: OfflineAlbumStorageProjection?

    public init(
        totalFrames: Int,
        cacheableFrames: Int,
        accuracy: OfflineAlbumProjectionAccuracy,
        fullyOffline: Bool,
        storage: OfflineAlbumStorageProjection? = nil
    ) {
        self.totalFrames = totalFrames
        self.cacheableFrames = cacheableFrames
        self.accuracy = accuracy
        self.fullyOffline = fullyOffline
        self.storage = storage
    }
}

public enum OfflineAlbumObservationState: String, Codable, Hashable, Sendable {
    case syncing
    case playing
    case paused
    case error
}

public struct OfflineAlbumObservation: Codable, Hashable, Sendable {
    public let state: OfflineAlbumObservationState
    public let cached: Int?
    public let total: Int?
    public let version: String?
    public let observedAt: Date

    public init(
        state: OfflineAlbumObservationState,
        cached: Int? = nil,
        total: Int? = nil,
        version: String? = nil,
        observedAt: Date
    ) {
        self.state = state
        self.cached = cached
        self.total = total
        self.version = version
        self.observedAt = observedAt
    }
}

public struct OfflineAlbumTarget: Codable, Hashable, Sendable {
    public let deviceID: String
    public let support: DeviceCapabilitySupport
    public let conflict: OfflineAlbumConflictClaim?
    public let plan: OfflineAlbumPlan?
    public let desiredVersion: String?
    public let observed: OfflineAlbumObservation?

    public init(
        deviceID: String,
        support: DeviceCapabilitySupport,
        conflict: OfflineAlbumConflictClaim? = nil,
        plan: OfflineAlbumPlan? = nil,
        desiredVersion: String? = nil,
        observed: OfflineAlbumObservation? = nil
    ) {
        self.deviceID = deviceID
        self.support = support
        self.conflict = conflict
        self.plan = plan
        self.desiredVersion = desiredVersion
        self.observed = observed
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "deviceId"
        case support
        case conflict
        case plan
        case desiredVersion
        case observed
    }
}

public struct OfflineAlbumResponse: Codable, Hashable, Sendable {
    public let album: OfflineAlbum
    public let targets: [OfflineAlbumTarget]

    public init(album: OfflineAlbum, targets: [OfflineAlbumTarget]) {
        self.album = album
        self.targets = targets
    }
}

public struct VersionedOfflineAlbum: Hashable, Sendable {
    public let response: OfflineAlbumResponse
    public let eTag: String

    public init(response: OfflineAlbumResponse, eTag: String) {
        self.response = response
        self.eTag = eTag
    }
}

public struct OfflineAlbumPreflightResponse: Codable, Hashable, Sendable {
    public let folderID: String
    public let targets: [OfflineAlbumTarget]

    public init(folderID: String, targets: [OfflineAlbumTarget]) {
        self.folderID = folderID
        self.targets = targets
    }

    private enum CodingKeys: String, CodingKey {
        case folderID = "folderId"
        case targets
    }
}
