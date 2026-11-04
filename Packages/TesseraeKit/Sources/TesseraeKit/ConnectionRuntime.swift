import Foundation

public struct CloudAuthorizedTransport: Sendable {
    public let issuer: URL
    public let fence: ConnectionFence
    private let sessions: SharedSessionStore
    private let transport: any TesseraeHTTPTransporting

    init(issuer: URL, fence: ConnectionFence, sessions: SharedSessionStore, transport: any TesseraeHTTPTransporting) {
        self.issuer = issuer
        self.fence = fence
        self.sessions = sessions
        self.transport = transport
    }

    public func send(_ original: URLRequest, timeout: TimeInterval = 10, authorizationTimeout: TimeInterval? = nil) async throws -> TesseraeHTTPResponse {
        guard let url = original.url, url.scheme == issuer.scheme, url.host == issuer.host, url.port == issuer.port,
              url.path.hasPrefix(issuer.appending(path: "api/t").path + "/") else { throw ConnectionError.invalidIdentity }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let first = try await sessions.authorization(for: fence, timeout: min(timeout, authorizationTimeout ?? timeout))
        var request = original
        request.setValue("Bearer \(first.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let result = try await sendWithinBudget(request, deadline: deadline)
        try await sessions.validate(fence, timeout: min(max(0, deadline - ProcessInfo.processInfo.systemUptime), authorizationTimeout ?? timeout))
        // Only safe reads may be repeated. Sending and rendering are owned by A3, without automatic replay.
        guard result.statusCode == 401, ["GET", "HEAD"].contains(request.httpMethod ?? "GET") else { return result }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ConnectionError.coordinationTimeout }
        let next = try await sessions.authorization(for: fence, timeout: min(remaining, authorizationTimeout ?? remaining), rejecting: first)
        request.setValue("Bearer \(next.token)", forHTTPHeaderField: "Authorization")
        let retried = try await sendWithinBudget(request, deadline: deadline)
        try await sessions.validate(fence, timeout: min(max(0, deadline - ProcessInfo.processInfo.systemUptime), authorizationTimeout ?? timeout))
        return retried
    }

    private func sendWithinBudget(_ request: URLRequest, deadline: TimeInterval) async throws -> TesseraeHTTPResponse {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw ConnectionError.coordinationTimeout }
        var prepared = request
        prepared.timeoutInterval = max(0.001, min(prepared.timeoutInterval, remaining))
        let frozen = prepared
        return try await boundedHTTP(timeout: remaining) { try await transport.send(frozen) }
    }
}

public struct ConnectionRuntime: Sendable {
    public let registry: ConnectionRegistry
    public let sessions: SharedSessionStore
    public let stateStore: ConnectionStateStore
    private let credentials: any CredentialStoring
    private let identity: TesseraeClientIdentity
    private let transport: any TesseraeHTTPTransporting
    private let cloudHTTPTransport: any TesseraeHTTPTransporting

    public init(directory: URL, suiteName: String?, keychainService: String, accessGroup: String?,
                identity: TesseraeClientIdentity, isPrimary: Bool,
                transport: (any TesseraeHTTPTransporting)? = nil) {
        let credentials = KeychainCredentialStore(service: keychainService, accessGroup: accessGroup)
        let sessions = SharedSessionStore(directory: directory,
            vault: KeychainSessionVault(service: keychainService, accessGroup: accessGroup),
            transport: transport ?? URLSessionTesseraeTransport.cloud())
        self.init(directory: directory, identity: identity, credentials: credentials, sessions: sessions,
            legacy: UserDefaultsCompanionStateStore(suiteName: suiteName), isPrimary: isPrimary,
            transport: transport, suiteName: suiteName)
    }

    public init(directory: URL, identity: TesseraeClientIdentity, credentials: any CredentialStoring,
                sessions: SharedSessionStore, legacy: any CompanionStateStoring, isPrimary: Bool,
                transport: (any TesseraeHTTPTransporting)? = nil, suiteName: String? = nil) {
        registry = ConnectionRegistry(directory: directory)
        self.sessions = sessions
        stateStore = ConnectionStateStore(registry: registry, sessions: sessions, legacy: legacy,
                                          legacyCredentials: credentials, isPrimary: isPrimary, suiteName: suiteName)
        self.credentials = credentials
        self.identity = identity
        self.transport = transport ?? URLSessionTesseraeTransport()
        cloudHTTPTransport = transport ?? URLSessionTesseraeTransport.cloud()
    }

    public func bootstrapClient() -> LiveTesseraeClient {
        LiveTesseraeClient(credentials: credentials, identity: identity, transport: transport, sessions: sessions)
    }

    public func client(for snapshot: CompanionSnapshot) throws -> LiveTesseraeClient {
        guard let fence = snapshot.connectionFence,
              fence.connectionID == snapshot.activeInstance.connectionIdentity.id else { throw ConnectionError.invalidIdentity }
        return LiveTesseraeClient(credentials: credentials, identity: identity, transport: transport,
                                  sessions: sessions, connectionFence: fence)
    }

    public static func localClient(credentials: any CredentialStoring, identity: TesseraeClientIdentity) -> LiveTesseraeClient {
        LiveTesseraeClient(credentials: credentials, identity: identity)
    }

    public func installLocal(_ paired: PairedSession) async throws -> ConnectionFence {
        let fence = try await sessions.installLocal(instance: paired.instance, token: paired.token)
        let old = try registry.connection(fence.connectionID)
        try await sessions.commit(fence) {
            try registry.save(SavedConnection(identity: paired.instance.connectionIdentity, name: paired.instance.name,
                localInstance: paired.instance, legacyInstanceID: old?.legacyInstanceID))
            try registry.select(fence.connectionID)
        }
        return fence
    }

    @discardableResult
    public func installCloud(issuer: URL, response: CloudTokenResponse) async throws -> ConnectionFence {
        let issuer = try ConnectionIdentity.canonicalService(issuer)
        let fence = try await sessions.installCloud(issuer: issuer, response: response)
        try registry.save(SavedConnection(identity: .cloud(issuer: issuer, userID: response.user.id, tenantID: response.tenant.id),
                                          name: "\(response.tenant.name) · \(response.user.email)"))
        return fence
    }

    public func cloudTransport(for id: ConnectionID) async throws -> CloudAuthorizedTransport {
        guard let connection = try registry.connection(id), case let .cloud(issuer, _, _) = connection.identity,
              let fence = try await sessions.fence(for: id) else { throw ConnectionError.invalidIdentity }
        try await sessions.validate(fence)
        return CloudAuthorizedTransport(issuer: issuer, fence: fence, sessions: sessions, transport: cloudHTTPTransport)
    }

    public func activate(_ id: ConnectionID) async throws {
        guard let fence = try await sessions.fence(for: id) else { throw ConnectionError.signedOut }
        try await sessions.commit(fence) { try registry.select(id) }
    }

    public func signOut(_ fence: ConnectionFence) async throws {
        try await sessions.close(fence)
        do {
            try await sessions.whileClosed(fence) {
                try registry.clearSelection(ifMatching: fence.connectionID)
            }
        } catch ConnectionError.sessionChanged {
            // A newer login owns the selection. Only this old grant's revocation remains.
        }
        do { try await sessions.retryRevocations(for: fence.connectionID) }
        catch { throw ConnectionError.remoteRevocationUnconfirmed }
    }
}
