import CryptoKit
import Foundation

public struct ConnectionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    var fileComponent: String { SHA256.hash(data: Data(rawValue.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public enum ConnectionIdentity: Codable, Hashable, Sendable {
    case selfHosted(service: URL, instanceID: String)
    case cloud(issuer: URL, userID: String, tenantID: String)

    public static func local(_ instance: TesseraeInstance) throws -> Self {
        .selfHosted(service: try canonicalService(instance.baseURL), instanceID: instance.id)
    }

    public static func canonicalService(_ url: URL) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["https", "http"].contains(parts.scheme), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { throw ConnectionError.invalidIdentity }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) {
            parts.port = nil
        }
        parts.query = nil
        parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let result = parts.url else { throw ConnectionError.invalidIdentity }
        return result
    }

    public var id: ConnectionID {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Encoding this closed enum has no fallible custom values.
        let data = try! encoder.encode(self)
        return ConnectionID(rawValue: "connection-v2-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}

public struct ConnectionFence: Codable, Hashable, Sendable {
    public let connectionID: ConnectionID
    public let epoch: UUID

    public init(connectionID: ConnectionID, epoch: UUID) {
        self.connectionID = connectionID
        self.epoch = epoch
    }
}

public enum ConnectionError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentity, unavailable, sessionChanged, signedOut, coordinationTimeout
    case rotationOutcomeUnknown, authorizationRequired, accessRestricted(String), invalidTokenResponse
    case remoteRevocationUnconfirmed

    public var errorDescription: String? {
        switch self {
        case .invalidIdentity: "The saved connection identity is invalid."
        case .unavailable: "Shared connection storage is unavailable."
        case .sessionChanged: "This connection changed. Choose the destination again."
        case .signedOut: "Sign in to this connection again."
        case .coordinationTimeout: "Another process is updating this connection. Try again shortly."
        case .rotationOutcomeUnknown: "The sign-in update could not be confirmed. Sign in again."
        case .authorizationRequired: "This authorization expired or was revoked. Sign in again."
        case let .accessRestricted(reason): "Access to this connection is restricted (\(reason))."
        case .invalidTokenResponse: "The authorization service returned an invalid response."
        case .remoteRevocationUnconfirmed: "Signed out on this device. Remote revocation could not be confirmed."
        }
    }
}

public extension TesseraeInstance {
    var connectionIdentity: ConnectionIdentity {
        // Invalid URLs remain rejected by the transport; they cannot share a valid connection's storage.
        (try? .local(self)) ?? .selfHosted(service: baseURL, instanceID: id)
    }

    var storageID: String { connectionIdentity.id.rawValue }
}

public struct ConnectionResourceID: Codable, Hashable, Sendable {
    public let connectionID: ConnectionID
    public let kind: String
    public let resourceID: String

    public init(connectionID: ConnectionID, kind: String, resourceID: String) {
        self.connectionID = connectionID
        self.kind = kind
        self.resourceID = resourceID
    }

    public var encoded: String {
        let bytes = try! JSONEncoder().encode(self)
        return "tesserae-resource-v2:" + bytes.base64EncodedString()
    }

    public init?(encoded: String) {
        let prefix = "tesserae-resource-v2:"
        guard encoded.hasPrefix(prefix), let data = Data(base64Encoded: String(encoded.dropFirst(prefix.count))),
              let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = decoded
    }
}
