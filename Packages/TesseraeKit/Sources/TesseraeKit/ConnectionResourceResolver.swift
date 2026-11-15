import Foundation

public enum ConnectionResourceKind: String, Sendable { case display, dashboard }

public struct ResolvedConnectionResources: Sendable {
    public let connection: SavedConnection
    public let resourceIDs: [String]
}

public struct ConnectionResourceResolver: Sendable {
    private let registry: ConnectionRegistry
    public init(registry: ConnectionRegistry) { self.registry = registry }

    public func resolve(_ identifiers: [String], kind: ConnectionResourceKind) throws -> ResolvedConnectionResources {
        guard !identifiers.isEmpty else { throw ConnectionError.invalidIdentity }
        let legacy = try registry.savedConnections().filter { $0.legacyInstanceID != nil && $0.localInstance != nil }
        var connectionID: ConnectionID?
        var resources: [String] = []
        for identifier in identifiers {
            let id: ConnectionID
            let resource: String
            if identifier.hasPrefix("tesserae-resource-v2:") {
                guard let decoded = ConnectionResourceID(encoded: identifier), decoded.kind == kind.rawValue else {
                    throw ConnectionError.invalidIdentity
                }
                id = decoded.connectionID; resource = decoded.resourceID
            } else {
                guard legacy.count == 1 else { throw ConnectionError.invalidIdentity }
                id = legacy[0].id; resource = identifier
            }
            guard !resource.isEmpty, resource != ".", resource != "..", !resource.contains(","),
                  connectionID == nil || connectionID == id, !resources.contains(resource) else {
                throw ConnectionError.invalidIdentity
            }
            connectionID = id; resources.append(resource)
        }
        guard let connectionID, let connection = try registry.connection(connectionID) else {
            throw ConnectionError.invalidIdentity
        }
        return .init(connection: connection, resourceIDs: resources)
    }
}
