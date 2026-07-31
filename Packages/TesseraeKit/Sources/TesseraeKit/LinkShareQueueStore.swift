import Foundation

public enum SharedLinkRequestStatus: String, Codable, Hashable, Sendable {
    case queued
    case submitting
    case failed
}

public struct SharedLinkRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let instanceID: String
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
    func remove(_ request: SharedLinkRequest) async throws
    func purge(expiredBefore date: Date) async throws
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
        try write(request, in: preparedDirectory())
    }

    public func remove(_ request: SharedLinkRequest) throws {
        let url = try metadataURL(for: request, in: preparedDirectory())
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw ShareQueueStoreError.writing(String(describing: error))
        }
    }

    public func purge(expiredBefore date: Date) throws {
        for request in try requests() where request.createdAt < date {
            try remove(request)
        }
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
