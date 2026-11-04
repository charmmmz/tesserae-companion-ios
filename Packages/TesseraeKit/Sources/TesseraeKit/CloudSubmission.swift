import Foundation

public struct CloudCompositionGeometry: Codable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              width * height <= 40_000_000 else { throw CloudSubmissionError.invalidPreparation }
        self.width = width
        self.height = height
    }
}

public struct CloudSubmissionTarget: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let geometry: CloudCompositionGeometry

    public init(id: String, name: String, geometry: CloudCompositionGeometry) {
        self.id = id
        self.name = name
        self.geometry = geometry
    }
}

public enum CloudRasterFormat: String, Codable, Sendable {
    case png = "image/png"
    case jpeg = "image/jpeg"
}

public struct CloudPhotoOutput: Sendable {
    public let data: Data
    public let format: CloudRasterFormat
    public let geometry: CloudCompositionGeometry
    public let targetIDs: [String]

    public init(data: Data, format: CloudRasterFormat, geometry: CloudCompositionGeometry, targetIDs: [String]) {
        self.data = data
        self.format = format
        self.geometry = geometry
        self.targetIDs = targetIDs
    }
}

public struct CloudFrameEvidence: Codable, Hashable, Sendable {
    public let digest: String
    public let bytes: Int
    public let renderedAt: Date?
    public let pageID: String?
}

public enum CloudSubmissionProblem: String, Codable, Sendable {
    case authorization, permission, quota, rateLimited, unavailable, invalidImage, missingTarget
    case interrupted, connectionChanged, invalidResponse, noFrame, network, storage, cancelled
    case deleted, mediaExpired, stopped
}

public enum CloudTargetOutcome: Codable, Hashable, Sendable {
    case generated(CloudFrameEvidence, warnings: [String])
    case refused(CloudSubmissionProblem, message: String, retryAfter: TimeInterval?)
    case unknown(CloudSubmissionProblem, message: String)
    case notAttempted(CloudSubmissionProblem)

    public var isCleanGenerated: Bool {
        if case .generated(_, let warnings) = self { return warnings.isEmpty }
        return false
    }
    public var needsDuplicateConfirmation: Bool {
        switch self { case .generated, .unknown: true; default: false }
    }
}

public struct CloudTargetResult: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let outcome: CloudTargetOutcome
}

public struct CloudSubmissionTask: Codable, Sendable, Identifiable {
    public let id: UUID
    public let targetIDs: [String]
    public let raster: CloudRasterReference?
    public var state: CloudSubmissionTaskState
}

public struct CloudRasterReference: Codable, Sendable {
    let fileID: UUID
    public let format: CloudRasterFormat
    public let geometry: CloudCompositionGeometry
    let digest: String
}

public struct CloudSubmissionClaim: Codable, Hashable, Sendable {
    public let attemptID: UUID
    public let runID: UUID
    public let fence: ConnectionFence
    public let claimedAt: Date
}

public enum CloudSubmissionTaskState: Codable, Sendable {
    case prepared
    case claimed(CloudSubmissionClaim)
    case resolved(CloudSubmissionClaim, [CloudTargetResult])
    case notAttempted(CloudSubmissionProblem)
}

public enum CloudSubmissionExecution: Codable, Sendable {
    case active(UUID)
    case stopped(CloudSubmissionProblem)
    case finished
}

public enum CloudSubmissionKind: String, Codable, Sendable { case photo, currentPage }

public struct CloudSubmissionBatch: Codable, Sendable, Identifiable {
    public let id: UUID
    public let identity: ConnectionIdentity
    public let fence: ConnectionFence
    public let kind: CloudSubmissionKind
    public let parentID: UUID?
    public let sourceRevision: Int?
    public let confirmedPossibleDuplicates: Bool
    public let createdAt: Date
    public let resultsExpireAt: Date
    public var mediaExpiresAt: Date?
    public let targets: [CloudSubmissionTarget]
    public var tasks: [CloudSubmissionTask]
    public var execution: CloudSubmissionExecution
    public var revision: Int
    let fingerprint: String
    var resendReservation: UUID?

    public var results: [CloudTargetResult] {
        tasks.flatMap { task -> [CloudTargetResult] in
            switch task.state {
            case .resolved(_, let results): results
            case .notAttempted(let reason): task.targetIDs.map { .init(id: $0, outcome: .notAttempted(reason)) }
            default: []
            }
        }
    }
    public var isActive: Bool { if case .active = execution { true } else { false } }
    public var initialUploadCount: Int { tasks.filter { $0.raster != nil }.count }
}

public struct CloudResendSelection: Sendable {
    public let targetIDs: Set<String>
    public let confirmsPossibleDuplicates: Bool

    public init(targetIDs: Set<String>, confirmsPossibleDuplicates: Bool) {
        self.targetIDs = targetIDs
        self.confirmsPossibleDuplicates = confirmsPossibleDuplicates
    }
}

public enum CloudSubmissionError: Error, LocalizedError, Equatable, Sendable {
    case invalidPreparation, decisionConflict, decisionClosed, missingResult, resultChanged
    case alreadyRunning, mediaUnavailable, changedGeometry, duplicateConfirmationRequired
    case interrupted, storageUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidPreparation: "This photo could not be prepared for the selected displays."
        case .decisionConflict: "This send decision already contains different content. Choose the photo again."
        case .decisionClosed: "This send has been deleted or expired. Create a new send."
        case .missingResult: "This send result is no longer available."
        case .resultChanged: "This result changed. Review the latest results before sending again."
        case .alreadyRunning: "This send is still in progress. Wait for its result."
        case .mediaUnavailable: "This photo was deleted or expired. Choose a photo to create a new send."
        case .changedGeometry: "The display changed. Review its preview before sending."
        case .duplicateConfirmationRequired: "Some displays may already have received this photo. Confirm before sending again."
        case .interrupted: "This send was interrupted. Check its results before sending again."
        case .storageUnavailable: "The send result could not be saved. Check the displays before sending again."
        }
    }
}
