import Foundation

public enum SharedLinkRequestStatus: String, Codable, Hashable, Sendable {
    case queued
    case submitting
    case failed
}

public struct SharedLinkRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let instanceID: String
    public let connectionEpoch: UUID?
    public let url: URL
    public let kind: LinkPushKind
    public let fit: ImageFitMode
    public let deviceIDs: [String]
    public let overrideQuietHours: Bool
    public let idempotencyKey: String
    public let createdAt: Date
    public let updatedAt: Date
    public let status: SharedLinkRequestStatus
    public let lastError: String?

    public init(
        id: String = UUID().uuidString,
        instanceID: String,
        connectionEpoch: UUID? = nil,
        url: URL,
        kind: LinkPushKind,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool = false,
        idempotencyKey: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: SharedLinkRequestStatus = .queued,
        lastError: String? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.connectionEpoch = connectionEpoch
        self.url = url
        self.kind = kind
        self.fit = fit
        self.deviceIDs = deviceIDs
        self.overrideQuietHours = overrideQuietHours
        self.idempotencyKey = idempotencyKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.lastError = lastError
    }

    public func updating(
        status: SharedLinkRequestStatus,
        error: String? = nil,
        at date: Date = Date()
    ) -> SharedLinkRequest {
        SharedLinkRequest(
            id: id,
            instanceID: instanceID,
            connectionEpoch: connectionEpoch,
            url: url,
            kind: kind,
            fit: fit,
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            updatedAt: date,
            status: status,
            lastError: error
        )
    }

    public func authorizingLocalRetry(instance: TesseraeInstance, fence: ConnectionFence) throws -> SharedLinkRequest {
        guard instanceID == instance.storageID, fence.connectionID == instance.connectionIdentity.id else {
            throw ConnectionError.sessionChanged
        }
        return SharedLinkRequest(
            id: id,
            instanceID: instanceID,
            connectionEpoch: fence.epoch,
            url: url,
            kind: kind,
            fit: fit,
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            createdAt: createdAt,
            updatedAt: updatedAt,
            status: self.status,
            lastError: lastError
        )
    }

    public var jobKind: PushJobKind {
        switch kind {
        case .imageURL:
            .imageURLPush
        case .webpage:
            .webpagePush
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case instanceID = "instanceId"
        case connectionEpoch
        case url
        case kind
        case fit
        case deviceIDs = "deviceIds"
        case overrideQuietHours
        case idempotencyKey
        case createdAt
        case updatedAt
        case status
        case lastError
    }
}

public protocol LinkShareQueueStoring: Sendable {
    func enqueue(_ request: SharedLinkRequest) async throws
    func requests() async throws -> [SharedLinkRequest]
    func update(_ request: SharedLinkRequest) async throws
    func authorizeLocalRetry(_ request: SharedLinkRequest, instance: TesseraeInstance, fence: ConnectionFence) async throws -> SharedLinkRequest
    func remove(_ request: SharedLinkRequest) async throws
    func purge(expiredBefore date: Date) async throws
}

public extension LinkShareQueueStoring {
    func authorizeLocalRetry(_ request: SharedLinkRequest, instance: TesseraeInstance, fence: ConnectionFence) async throws -> SharedLinkRequest {
        guard request.status != .submitting else { throw ShareQueueStoreError.requestInProgress }
        let rebound = try request.authorizingLocalRetry(instance: instance, fence: fence)
        try await update(rebound)
        return rebound
    }
}

public actor FileLinkShareQueueStore: LinkShareQueueStoring {
    private let directoryURL: URL?

    public init(directoryURL: URL?) {
        self.directoryURL = directoryURL?
            .appending(path: "LinkShareQueue", directoryHint: .isDirectory)
    }

    public func enqueue(_ request: SharedLinkRequest) throws {
        try write(request, in: preparedDirectory())
    }

    public func requests() throws -> [SharedLinkRequest] {
        let directory = try preparedDirectory()
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw ShareQueueStoreError.reading(String(describing: error))
        }
        return try urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                do {
                    return try TesseraeJSON.decoder().decode(
                        SharedLinkRequest.self,
                        from: Data(contentsOf: url)
                    )
                } catch {
                    throw ShareQueueStoreError.reading(String(describing: error))
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func update(_ request: SharedLinkRequest) throws {
        let directory = try preparedDirectory()
        try withRequestLock(request.id) {
            let url = try metadataURL(for: request, in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ShareQueueStoreError.missingImage }
            let existing = try TesseraeJSON.decoder().decode(SharedLinkRequest.self, from: Data(contentsOf: url))
            guard existing.instanceID == request.instanceID, existing.connectionEpoch == request.connectionEpoch,
                  existing.idempotencyKey == request.idempotencyKey else { throw ConnectionError.sessionChanged }
            try write(request, in: directory)
        }
    }

    public func authorizeLocalRetry(_ request: SharedLinkRequest, instance: TesseraeInstance, fence: ConnectionFence) async throws -> SharedLinkRequest {
        guard request.instanceID == instance.storageID, fence.connectionID == instance.connectionIdentity.id else {
            throw ConnectionError.sessionChanged
        }
        let directory = try preparedDirectory()
        return try withRequestLock(request.id) {
            let url = try metadataURL(for: request, in: directory)
            guard FileManager.default.fileExists(atPath: url.path) else { throw ShareQueueStoreError.missingImage }
            let current = try TesseraeJSON.decoder().decode(SharedLinkRequest.self, from: Data(contentsOf: url))
            guard current.status != .submitting else { throw ShareQueueStoreError.requestInProgress }
            guard current.instanceID == request.instanceID, current.connectionEpoch == request.connectionEpoch,
                  current.idempotencyKey == request.idempotencyKey else {
                throw ConnectionError.sessionChanged
            }
            let rebound = try current.authorizingLocalRetry(instance: instance, fence: fence)
            try write(rebound, in: directory)
            return rebound
        }
    }

    public func remove(_ request: SharedLinkRequest) throws {
        let directory = try preparedDirectory()
        try withRequestLock(request.id) {
            let metadata = try metadataURL(for: request, in: directory)
            if FileManager.default.fileExists(atPath: metadata.path) {
                let current = try TesseraeJSON.decoder().decode(SharedLinkRequest.self, from: Data(contentsOf: metadata))
                guard current.instanceID == request.instanceID, current.connectionEpoch == request.connectionEpoch else {
                    throw ConnectionError.sessionChanged
                }
            }
            let url = try metadataURL(for: request, in: directory)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    public func purge(expiredBefore date: Date) throws {
        for request in try requests() where request.createdAt < date {
            try remove(request)
        }
    }

    private func withRequestLock<T>(_ id: String, _ operation: () throws -> T) throws -> T {
        let directory = try preparedDirectory()
        let component = ConnectionID(rawValue: id).fileComponent
        return try SharedFileLock(url: directory.appending(path: "Locks/\(component).lock")).withLock { try operation() }
    }

    private func preparedDirectory() throws -> URL {
        guard let directoryURL else {
            throw ShareQueueStoreError.unavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return directoryURL
        } catch {
            throw ShareQueueStoreError.writing(String(describing: error))
        }
    }

    private func write(
        _ request: SharedLinkRequest,
        in directory: URL
    ) throws {
        do {
            try TesseraeJSON.encoder()
                .encode(request)
                .write(
                    to: metadataURL(for: request, in: directory),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
        } catch let error as ShareQueueStoreError {
            throw error
        } catch {
            throw ShareQueueStoreError.writing(String(describing: error))
        }
    }

    private func metadataURL(
        for request: SharedLinkRequest,
        in directory: URL
    ) throws -> URL {
        guard
            !request.id.isEmpty,
            request.id.allSatisfy({
                $0.isLetter || $0.isNumber || $0 == "-"
            })
        else {
            throw ShareQueueStoreError.invalidRequestID
        }
        return directory.appending(path: "\(request.id).json")
    }
}

public actor InMemoryLinkShareQueueStore: LinkShareQueueStoring {
    private var records: [String: SharedLinkRequest] = [:]

    public init() {}

    public func enqueue(_ request: SharedLinkRequest) {
        records[request.id] = request
    }

    public func requests() -> [SharedLinkRequest] {
        records.values.sorted { $0.createdAt < $1.createdAt }
    }

    public func update(_ request: SharedLinkRequest) {
        records[request.id] = request
    }

    public func remove(_ request: SharedLinkRequest) {
        records.removeValue(forKey: request.id)
    }

    public func purge(expiredBefore date: Date) {
        records = records.filter { $0.value.createdAt >= date }
    }
}
