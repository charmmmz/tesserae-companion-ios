@preconcurrency import Foundation

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

public enum TesseraeDiscoveryError: Error, Equatable, LocalizedError, Sendable {
    case browser(String)

    public var errorDescription: String? {
        switch self {
        case let .browser(message):
            "Tesserae discovery failed: \(message)"
        }
    }
}

public actor BonjourDiscoveryService: TesseraeDiscovering {
    private let browseDuration: Duration
    private let resolutionTimeout: Duration

    public init(
        browseDuration: Duration = .seconds(2),
        resolutionTimeout: Duration = .seconds(2)
    ) {
        self.browseDuration = browseDuration
        self.resolutionTimeout = resolutionTimeout
    }

    public func instances() async throws -> [DiscoveredInstance] {
        let session = await MainActor.run {
            BonjourNetServiceSession(resolutionTimeout: resolutionTimeout)
        }
        return try await session.discover(for: browseDuration)
    }
}

@MainActor
private final class BonjourNetServiceSession: NSObject, @unchecked Sendable {
    private let browser = NetServiceBrowser()
    private let resolutionTimeout: TimeInterval
    private var services: [String: NetService] = [:]
    private var resolved: [String: DiscoveredInstance] = [:]
    private var failure: String?

    init(resolutionTimeout: Duration) {
        self.resolutionTimeout = Self.seconds(from: resolutionTimeout)
        super.init()
        browser.delegate = self
    }

    func discover(for duration: Duration) async throws -> [DiscoveredInstance] {
        browser.searchForServices(
            ofType: "_tesserae._tcp.",
            inDomain: "local."
        )
        try await Task.sleep(for: duration)
        browser.stop()
        services.values.forEach { $0.stop() }

        if let failure {
            throw TesseraeDiscoveryError.browser(failure)
        }
        return resolved.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func seconds(from duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

extension BonjourNetServiceSession:
    @MainActor NetServiceBrowserDelegate,
    @MainActor NetServiceDelegate
{
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.type)\(service.domain)"
        services[key] = service
        service.delegate = self
        service.resolve(withTimeout: resolutionTimeout)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        let key = "\(service.name).\(service.type)\(service.domain)"
        services.removeValue(forKey: key)
        resolved.removeValue(forKey: key)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didNotSearch errorDict: [String: NSNumber]
    ) {
        failure = errorDict.description
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard
            var host = sender.hostName,
            sender.port > 0
        else {
            return
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = sender.port
        guard let baseURL = components.url else {
            return
        }
        let key = "\(sender.name).\(sender.type)\(sender.domain)"
        resolved[key] = DiscoveredInstance(
            id: baseURL.absoluteString,
            name: sender.name,
            baseURL: baseURL
        )
    }
}
