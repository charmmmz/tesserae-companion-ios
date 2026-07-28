import Foundation

public struct DiscoveredInstance: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let baseURL: URL

    public init(id: String, name: String, baseURL: URL) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }
}

public protocol TesseraeDiscovering: Sendable {
    func instances() async throws -> [DiscoveredInstance]
}

public struct StaticDiscoveryService: TesseraeDiscovering {
    private let results: [DiscoveredInstance]

    public init(results: [DiscoveredInstance]) {
        self.results = results
    }

    public func instances() async throws -> [DiscoveredInstance] {
        results
    }
}

