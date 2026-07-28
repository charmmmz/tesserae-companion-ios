import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ActivityThumbnailPolicy: Equatable, Sendable {
    public let maximumPixelEdge: Int
    public let jpegQuality: Double
    public let retentionInterval: TimeInterval
    public let maximumCount: Int
    public let maximumTotalBytes: Int

    public init(
        maximumPixelEdge: Int = 480,
        jpegQuality: Double = 0.72,
        retentionInterval: TimeInterval = 30 * 24 * 60 * 60,
        maximumCount: Int = 100,
        maximumTotalBytes: Int = 15 * 1_024 * 1_024
    ) {
        self.maximumPixelEdge = max(1, maximumPixelEdge)
        self.jpegQuality = min(max(jpegQuality, 0), 1)
        self.retentionInterval = max(0, retentionInterval)
        self.maximumCount = max(1, maximumCount)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
    }
}

public protocol ActivityThumbnailStoring: Sendable {
    @discardableResult
    func save(
        imageData: Data,
        jobID: String,
        instanceID: String,
        createdAt: Date
    ) async throws -> Data

    func data(
        forJobID jobID: String,
        instanceID: String
    ) async throws -> Data?

    func purge(referenceDate: Date) async throws
    func clear(instanceID: String) async throws
}

public enum ActivityThumbnailStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case decoding
    case encoding
    case reading(String)
    case writing(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Activity photo storage is unavailable."
        case .decoding:
            "The sent photo could not be decoded for Activity."
        case .encoding:
            "The sent photo preview could not be created."
        case .reading:
            "An Activity photo preview could not be read."
        case .writing:
            "The Activity photo preview could not be saved."
        }
    }
}

public actor FileActivityThumbnailStore: ActivityThumbnailStoring {
    private struct Record: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let jobID: String
        let instanceID: String
        let createdAt: Date
        let byteCount: Int
        let imageFileName: String

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case jobID = "jobId"
            case instanceID = "instanceId"
            case createdAt
            case byteCount
            case imageFileName
        }
    }

    private let directoryURL: URL?
    private let policy: ActivityThumbnailPolicy

    public init(
        directoryURL: URL?,
        policy: ActivityThumbnailPolicy = ActivityThumbnailPolicy()
    ) {
        self.directoryURL = directoryURL?
            .appending(path: "ActivityThumbnails", directoryHint: .isDirectory)
        self.policy = policy
    }

    @discardableResult
    public func save(
        imageData: Data,
        jobID: String,
        instanceID: String,
        createdAt: Date = Date()
    ) throws -> Data {
        let directory = try preparedDirectory()
        let thumbnail = try Self.makeThumbnail(
            from: imageData,
            policy: policy
        )
        let stem = fileStem(jobID: jobID, instanceID: instanceID)
        let imageFileName = "\(stem).jpg"
        let imageURL = directory.appending(path: imageFileName)
        let recordURL = directory.appending(path: "\(stem).json")
        let record = Record(
            schemaVersion: 1,
            jobID: jobID,
            instanceID: instanceID,
            createdAt: createdAt,
            byteCount: thumbnail.count,
            imageFileName: imageFileName
        )

        do {
            try thumbnail.write(
                to: imageURL,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            try TesseraeJSON.encoder()
                .encode(record)
                .write(
                    to: recordURL,
                    options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
                )
            try purge(referenceDate: Date())
            return thumbnail
        } catch let error as ActivityThumbnailStoreError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: recordURL)
            throw ActivityThumbnailStoreError.writing(String(describing: error))
        }
    }

    public func data(
        forJobID jobID: String,
        instanceID: String
    ) throws -> Data? {
        let directory = try preparedDirectory()
        let url = directory.appending(
            path: "\(fileStem(jobID: jobID, instanceID: instanceID)).jpg"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ActivityThumbnailStoreError.reading(String(describing: error))
        }
    }

    public func purge(referenceDate: Date = Date()) throws {
        let directory = try preparedDirectory()
        let cutoff = referenceDate.addingTimeInterval(-policy.retentionInterval)
        let records = try records(in: directory)
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt > rhs.createdAt
                }
                return lhs.jobID < rhs.jobID
            }

        var retainedCount = 0
        var retainedBytes = 0
        for record in records {
            let fitsPolicy = record.createdAt >= cutoff
                && retainedCount < policy.maximumCount
                && retainedBytes + record.byteCount <= policy.maximumTotalBytes
            if fitsPolicy {
                retainedCount += 1
                retainedBytes += record.byteCount
            } else {
                try remove(record, from: directory)
            }
        }
    }

    public func clear(instanceID: String) throws {
        let directory = try preparedDirectory()
        for record in try records(in: directory)
        where record.instanceID == instanceID {
            try remove(record, from: directory)
        }
    }

    private func preparedDirectory() throws -> URL {
        guard let directoryURL else {
            throw ActivityThumbnailStoreError.unavailable
        }
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            return directoryURL
        } catch {
            throw ActivityThumbnailStoreError.writing(String(describing: error))
        }
    }

    private func records(in directory: URL) throws -> [Record] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )
        } catch {
            throw ActivityThumbnailStoreError.reading(String(describing: error))
        }

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard
                    let data = try? Data(contentsOf: url),
                    let record = try? TesseraeJSON.decoder().decode(
                        Record.self,
                        from: data
                    ),
                    record.schemaVersion == 1
                else {
                    return nil
                }
                return record
            }
    }

    private func remove(_ record: Record, from directory: URL) throws {
        let stem = fileStem(jobID: record.jobID, instanceID: record.instanceID)
        for url in [
            directory.appending(path: record.imageFileName),
            directory.appending(path: "\(stem).json"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw ActivityThumbnailStoreError.writing(String(describing: error))
            }
        }
    }

    private func fileStem(jobID: String, instanceID: String) -> String {
        "\(Self.fileToken(instanceID))--\(Self.fileToken(jobID))"
    }

    private static func fileToken(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    fileprivate static func makeThumbnail(
        from imageData: Data,
        policy: ActivityThumbnailPolicy
    ) throws -> Data {
        guard
            let source = CGImageSourceCreateWithData(imageData as CFData, nil),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: policy.maximumPixelEdge,
                ] as CFDictionary
            )
        else {
            throw ActivityThumbnailStoreError.decoding
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ActivityThumbnailStoreError.encoding
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyOrientation: 1,
                kCGImageDestinationLossyCompressionQuality: policy.jpegQuality,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ActivityThumbnailStoreError.encoding
        }
        return output as Data
    }
}

public actor InMemoryActivityThumbnailStore: ActivityThumbnailStoring {
    private struct Key: Hashable {
        let jobID: String
        let instanceID: String
    }

    private let policy: ActivityThumbnailPolicy
    private var values: [Key: (data: Data, createdAt: Date)] = [:]

    public init(policy: ActivityThumbnailPolicy = ActivityThumbnailPolicy()) {
        self.policy = policy
    }

    @discardableResult
    public func save(
        imageData: Data,
        jobID: String,
        instanceID: String,
        createdAt: Date = Date()
    ) throws -> Data {
        let thumbnail = try FileActivityThumbnailStore.makeThumbnail(
            from: imageData,
            policy: policy
        )
        values[Key(jobID: jobID, instanceID: instanceID)] = (
            thumbnail,
            createdAt
        )
        try purge(referenceDate: Date())
        return thumbnail
    }

    public func data(
        forJobID jobID: String,
        instanceID: String
    ) -> Data? {
        values[Key(jobID: jobID, instanceID: instanceID)]?.data
    }

    public func purge(referenceDate: Date = Date()) throws {
        let cutoff = referenceDate.addingTimeInterval(-policy.retentionInterval)
        let ordered = values.sorted { lhs, rhs in
            lhs.value.createdAt > rhs.value.createdAt
        }
        var retainedCount = 0
        var retainedBytes = 0
        for (key, value) in ordered {
            let keep = value.createdAt >= cutoff
                && retainedCount < policy.maximumCount
                && retainedBytes + value.data.count <= policy.maximumTotalBytes
            if keep {
                retainedCount += 1
                retainedBytes += value.data.count
            } else {
                values.removeValue(forKey: key)
            }
        }
    }

    public func clear(instanceID: String) {
        values = values.filter { $0.key.instanceID != instanceID }
    }
}
