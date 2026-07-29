import Foundation

public struct CompanionSendPreferences: Codable, Hashable, Sendable {
    public let instanceID: String
    public let deviceIDs: [String]
    public let imageFitMode: ImageFitMode

    public init(
        instanceID: String,
        deviceIDs: [String],
        imageFitMode: ImageFitMode
    ) {
        self.instanceID = instanceID
        self.deviceIDs = Array(Set(deviceIDs)).sorted()
        self.imageFitMode = imageFitMode
    }

    private enum CodingKeys: String, CodingKey {
        case instanceID = "instanceId"
        case deviceIDs = "deviceIds"
        case imageFitMode
    }
}

public protocol CompanionSendPreferencesStoring: Sendable {
    func preferences(
        for instanceID: String
    ) async throws -> CompanionSendPreferences?
    func save(_ preferences: CompanionSendPreferences) async throws
    func removePreferences(for instanceID: String) async throws
}

public enum CompanionSendPreferencesStoreError:
    Error,
    Equatable,
    LocalizedError,
    Sendable
{
    case unavailable
    case decoding(String)
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "Shared Tesserae send preferences are unavailable."
        case .decoding:
            "Stored Tesserae send preferences could not be read."
        case .encoding:
            "Tesserae send preferences could not be saved."
        }
    }
}

public actor UserDefaultsCompanionSendPreferencesStore:
    CompanionSendPreferencesStoring
{
    private let defaults: UserDefaults?
    private let key: String

    public init(
        suiteName: String?,
        key: String = "TesseraeCompanionSendPreferences"
    ) {
        if let suiteName {
            defaults = UserDefaults(suiteName: suiteName)
        } else {
            defaults = .standard
        }
        self.key = key
    }

    public func preferences(
        for instanceID: String
    ) throws -> CompanionSendPreferences? {
        try allPreferences()[instanceID]
    }

    public func save(_ preferences: CompanionSendPreferences) throws {
        var stored = try allPreferences()
        stored[preferences.instanceID] = preferences
        try write(stored)
    }

    public func removePreferences(for instanceID: String) throws {
        var stored = try allPreferences()
        stored.removeValue(forKey: instanceID)
        try write(stored)
    }

    private func allPreferences() throws -> [String: CompanionSendPreferences] {
        guard let defaults else {
            throw CompanionSendPreferencesStoreError.unavailable
        }
        guard let data = defaults.data(forKey: key) else {
            return [:]
        }
        do {
            return try TesseraeJSON.decoder().decode(
                [String: CompanionSendPreferences].self,
                from: data
            )
        } catch {
            throw CompanionSendPreferencesStoreError.decoding(
                String(describing: error)
            )
        }
    }

    private func write(
        _ preferences: [String: CompanionSendPreferences]
    ) throws {
        guard let defaults else {
            throw CompanionSendPreferencesStoreError.unavailable
        }
        do {
            defaults.set(
                try TesseraeJSON.encoder().encode(preferences),
                forKey: key
            )
        } catch {
            throw CompanionSendPreferencesStoreError.encoding(
                String(describing: error)
            )
        }
    }
}

public actor InMemoryCompanionSendPreferencesStore:
    CompanionSendPreferencesStoring
{
    private var stored: [String: CompanionSendPreferences]

    public init(preferences: [CompanionSendPreferences] = []) {
        stored = Dictionary(
            preferences.map { ($0.instanceID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
    }

    public func preferences(
        for instanceID: String
    ) -> CompanionSendPreferences? {
        stored[instanceID]
    }

    public func save(_ preferences: CompanionSendPreferences) {
        stored[preferences.instanceID] = preferences
    }

    public func removePreferences(for instanceID: String) {
        stored.removeValue(forKey: instanceID)
    }
}
