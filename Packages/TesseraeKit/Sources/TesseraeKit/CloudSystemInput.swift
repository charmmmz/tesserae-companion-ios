import Foundation

public struct CloudEntryTargets: Codable, Sendable {
    public let connectionID: ConnectionID
    public let deviceIDs: [String]
    public let reviewedFence: ConnectionFence?
    public let reviewedGeometry: [String: CloudCompositionGeometry]

    public init(connectionID: ConnectionID, deviceIDs: [String], reviewedFence: ConnectionFence? = nil,
                reviewedGeometry: [String: CloudCompositionGeometry] = [:]) throws {
        guard !deviceIDs.isEmpty, Set(deviceIDs).count == deviceIDs.count,
              deviceIDs.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(",") }),
              reviewedFence == nil || reviewedFence?.connectionID == connectionID,
              Set(reviewedGeometry.keys).isSubset(of: Set(deviceIDs)) else { throw ConnectionError.invalidIdentity }
        self.connectionID = connectionID; self.deviceIDs = deviceIDs
        self.reviewedFence = reviewedFence; self.reviewedGeometry = reviewedGeometry
    }
}

public struct CloudPhotoRecipe: Codable, Sendable {
    public let fit: ImageFitMode
    public let framings: [PanelAspectRatio: ImageFraming]
    public init(fit: ImageFitMode, framings: [PanelAspectRatio: ImageFraming] = [:]) {
        self.fit = fit; self.framings = framings
    }
}

public enum CloudEntryRequest: Sendable {
    case photo(targets: CloudEntryTargets, data: Data, contentType: String, recipe: CloudPhotoRecipe)
    case currentPage(CloudEntryTargets)
    var targets: CloudEntryTargets {
        switch self { case .photo(let targets, _, _, _), .currentPage(let targets): targets }
    }
}

public struct CloudPhotoPreparation: Sendable {
    public let targets: [CloudSubmissionTarget]
    public let outputs: [CloudPhotoOutput]
    public init(targets: [CloudSubmissionTarget], outputs: [CloudPhotoOutput]) {
        self.targets = targets; self.outputs = outputs
    }
}

public struct CloudPendingInput: Sendable, Identifiable {
    public let id: UUID
    public let identity: ConnectionIdentity
    public let createdAt: Date
    public let expiresAt: Date
    public let targets: CloudEntryTargets
    public let kind: CloudSubmissionKind
    public let recipe: CloudPhotoRecipe?
    public let revision: Int
}

struct CloudInputRecord: Codable, Sendable {
    let id: UUID
    let identity: ConnectionIdentity
    let createdAt: Date
    let expiresAt: Date
    let targets: CloudEntryTargets
    let kind: CloudSubmissionKind
    let recipe: CloudPhotoRecipe?
    var revision: Int
    var boundFence: ConnectionFence?
    let source: CloudInputFile?
    let fingerprint: String
    var summary: CloudPendingInput {
        .init(id: id, identity: identity, createdAt: createdAt, expiresAt: expiresAt,
              targets: targets, kind: kind, recipe: recipe, revision: revision)
    }
}

struct CloudInputFile: Codable, Sendable {
    let id: UUID
    let contentType: String
    let digest: String
    let byteCount: Int
}

struct CloudOwnedInput: Sendable {
    let input: CloudInputRecord
    let owner: CloudRunOwner
}

enum CloudInputAdmission: Sendable {
    case owned(CloudOwnedInput)
    case pending(CloudInputRecord, isLive: Bool)
    case batch(CloudSubmissionBatch)
}

public enum CloudEntryCompletion: Sendable {
    case finished(CloudSubmissionBatch)
    case retained(CloudPendingInput, message: String)
    case inProgress(decision: UUID)
    case notConfirmed(decision: UUID, message: String)
}

public struct CloudEntryReadContext: Sendable {
    public let fence: ConnectionFence
    let snapshot: CloudBootstrap
}

struct CloudEntryDeadline: Sendable {
    let uptime: TimeInterval
    init(timeout: TimeInterval) throws {
        guard timeout > 0, timeout.isFinite else { throw ConnectionError.coordinationTimeout }
        uptime = ProcessInfo.processInfo.systemUptime + timeout
    }
    init(uptime: TimeInterval) { self.uptime = uptime }
    func remaining(limit: TimeInterval = .greatestFiniteMagnitude) throws -> TimeInterval {
        try Task.checkCancellation()
        let left = min(limit, uptime - ProcessInfo.processInfo.systemUptime)
        guard left > 0 else { throw ConnectionError.coordinationTimeout }
        return left
    }
}
