import Foundation

public struct CompanionSnapshot: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let activeInstance: TesseraeInstance
    public let capabilities: ServerCapabilities?
    public let displays: [DisplaySummary]
    public let dashboards: [DashboardSummary]
    public let jobs: [PushJob]
    public let updatedAt: Date

    public init(
        schemaVersion: Int = currentSchemaVersion,
        activeInstance: TesseraeInstance,
        capabilities: ServerCapabilities?,
        displays: [DisplaySummary],
        dashboards: [DashboardSummary],
        jobs: [PushJob],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.activeInstance = activeInstance
        self.capabilities = capabilities
        self.displays = displays
        self.dashboards = dashboards
        self.jobs = jobs
        self.updatedAt = updatedAt
    }
}

public protocol CompanionStateStoring: Sendable {
    func load() async throws -> CompanionSnapshot?
    func save(_ snapshot: CompanionSnapshot) async throws
    func clear() async throws
}

public enum CompanionStateStoreError: Error, Equatable, LocalizedError, Sendable {
    case unavailable
    case unsupportedSchema(Int)
    case decoding(String)
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Shared Tesserae app storage is unavailable."
        case let .unsupportedSchema(version):
            "Stored Tesserae connection data uses unsupported schema \(version)."
        case .decoding:
            "Stored Tesserae connection data could not be read."
        case .encoding:
            "Tesserae connection data could not be saved."
        }
    }
}

public actor UserDefaultsCompanionStateStore: CompanionStateStoring {
    private let defaults: UserDefaults?
    private let key: String

    public init(
        suiteName: String?,
        key: String = "TesseraeCompanionSnapshot"
    ) {
        if let suiteName {
            defaults = UserDefaults(suiteName: suiteName)
        } else {
            defaults = .standard
        }
        self.key = key
    }

    public func load() throws -> CompanionSnapshot? {
        guard let defaults else {
            throw CompanionStateStoreError.unavailable
        }
        guard let data = defaults.data(forKey: key) else {
            return nil
        }

        let snapshot: CompanionSnapshot
        do {
            snapshot = try TesseraeJSON.decoder().decode(
                CompanionSnapshot.self,
                from: data
            )
        } catch {
            throw CompanionStateStoreError.decoding(String(describing: error))
        }
        guard snapshot.schemaVersion == CompanionSnapshot.currentSchemaVersion else {
            throw CompanionStateStoreError.unsupportedSchema(snapshot.schemaVersion)
        }
        return snapshot
    }

    public func save(_ snapshot: CompanionSnapshot) throws {
        guard let defaults else {
            throw CompanionStateStoreError.unavailable
        }
        do {
            defaults.set(try TesseraeJSON.encoder().encode(snapshot), forKey: key)
        } catch {
            throw CompanionStateStoreError.encoding(String(describing: error))
        }
    }

    public func clear() throws {
        guard let defaults else {
            throw CompanionStateStoreError.unavailable
        }
        defaults.removeObject(forKey: key)
    }
}

public actor InMemoryCompanionStateStore: CompanionStateStoring {
    private var snapshot: CompanionSnapshot?

    public init(snapshot: CompanionSnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() -> CompanionSnapshot? {
        snapshot
    }

    public func save(_ snapshot: CompanionSnapshot) {
        self.snapshot = snapshot
    }

    public func clear() {
        snapshot = nil
    }
}
