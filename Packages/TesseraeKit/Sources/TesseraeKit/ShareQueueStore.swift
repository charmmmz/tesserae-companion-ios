import Foundation

public enum SharedImageRequestStatus: String, Codable, Hashable, Sendable {
    case queued
    case submitting
    case failed
}

public struct SharedImageRequest: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let instanceID: String
    public let fileName: String
    public let contentType: String
    public let fit: ImageFitMode
    public let deviceIDs: [String]
    public let overrideQuietHours: Bool
    public let idempotencyKey: String
    public let createdAt: Date
    public let updatedAt: Date
    public let status: SharedImageRequestStatus
    public let lastError: String?

    public init(
        id: String = UUID().uuidString,
        instanceID: String,
        fileName: String,
        contentType: String,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool = false,
        idempotencyKey: String = UUID().uuidString,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: SharedImageRequestStatus = .queued,
        lastError: String? = nil
    ) {
        self.id = id
        self.instanceID = instanceID
        self.fileName = fileName
        self.contentType = contentType
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
        status: SharedImageRequestStatus,
        error: String? = nil,
        at date: Date = Date()
    ) -> SharedImageRequest {
        SharedImageRequest(
            id: id,
            instanceID: instanceID,
            fileName: fileName,
            contentType: contentType,
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

    private enum CodingKeys: String, CodingKey {
        case id
        case instanceID = "instanceId"
        case fileName
        case contentType
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

public protocol ShareQueueStoring: Sendable {
    func enqueue(imageData: Data, request: SharedImageRequest) async throws
    func requests() async throws -> [SharedImageRequest]
    func imageData(for request: SharedImageRequest) async throws -> Data
    func update(_ request: SharedImageRequest) async throws
    func remove(_ request: SharedImageRequest) async throws
    func purge(expiredBefore date: Date) async throws
}

public enum ShareQueueStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case invalidRequestID
    case missingImage
    case reading(String)
    case writing(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Shared Tesserae transfer storage is unavailable."
        case .invalidRequestID:
            "The shared Tesserae request identifier is invalid."
        case .missingImage:
            "The shared image is no longer available."
        case .reading:
            "A queued Tesserae item could not be read."
        case .writing:
            "The shared item could not be queued for Tesserae."
        }
    }
}

public actor FileShareQueueStore: ShareQueueStoring {
    private let directoryURL: URL?

    public init(directoryURL: URL?) {
        self.directoryURL = directoryURL?
            .appending(path: "ShareQueue", directoryHint: .isDirectory)
    }

    public func enqueue(
        imageData: Data,
        request: SharedImageRequest
    ) throws {
        let directory = try preparedDirectory()
        do {
            try imageData.write(
                to: imageURL(for: request, in: directory),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try write(request, in: directory)
        } catch let error as ShareQueueStoreError {
            throw error
        } catch {
            try? FileManager.default.removeItem(
                at: imageURL(for: request, in: directory)
            )
            throw ShareQueueStoreError.writing(String(describing: error))
        }
    }

    public func requests() throws -> [SharedImageRequest] {
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
                        SharedImageRequest.self,
                        from: Data(contentsOf: url)
                    )
                } catch {
                    throw ShareQueueStoreError.reading(String(describing: error))
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func imageData(for request: SharedImageRequest) throws -> Data {
        let url = try imageURL(for: request, in: preparedDirectory())
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ShareQueueStoreError.missingImage
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ShareQueueStoreError.reading(String(describing: error))
        }
    }

    public func update(_ request: SharedImageRequest) throws {
        try write(request, in: preparedDirectory())
    }

    public func remove(_ request: SharedImageRequest) throws {
        let directory = try preparedDirectory()
        for url in [
            try imageURL(for: request, in: directory),
            try metadataURL(for: request, in: directory),
        ] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ShareQueueStoreError.writing(String(describing: error))
            }
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
        _ request: SharedImageRequest,
        in directory: URL
    ) throws {
        do {
            try TesseraeJSON.encoder()
                .encode(request)
                .write(
                    to: metadataURL(for: request, in: directory),
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
        } catch {
            throw ShareQueueStoreError.writing(String(describing: error))
        }
    }

    private func imageURL(
        for request: SharedImageRequest,
        in directory: URL
    ) throws -> URL {
        try validated(request.id)
        return directory.appending(path: "\(request.id).image")
    }

    private func metadataURL(
        for request: SharedImageRequest,
        in directory: URL
    ) throws -> URL {
        try validated(request.id)
        return directory.appending(path: "\(request.id).json")
    }

    private func validated(_ requestID: String) throws {
        guard
            !requestID.isEmpty,
            requestID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" })
        else {
            throw ShareQueueStoreError.invalidRequestID
        }
    }
}

public actor InMemoryShareQueueStore: ShareQueueStoring {
    private var records: [String: (request: SharedImageRequest, data: Data)] = [:]

    public init() {}

    public func enqueue(imageData: Data, request: SharedImageRequest) {
        records[request.id] = (request, imageData)
    }

    public func requests() -> [SharedImageRequest] {
        records.values.map(\.request).sorted { $0.createdAt < $1.createdAt }
    }

    public func imageData(for request: SharedImageRequest) throws -> Data {
        guard let record = records[request.id] else {
            throw ShareQueueStoreError.missingImage
        }
        return record.data
    }

    public func update(_ request: SharedImageRequest) throws {
        guard let record = records[request.id] else {
            throw ShareQueueStoreError.missingImage
        }
        records[request.id] = (request, record.data)
    }

    public func remove(_ request: SharedImageRequest) {
        records.removeValue(forKey: request.id)
    }

    public func purge(expiredBefore date: Date) {
        records = records.filter { $0.value.request.createdAt >= date }
    }
}
