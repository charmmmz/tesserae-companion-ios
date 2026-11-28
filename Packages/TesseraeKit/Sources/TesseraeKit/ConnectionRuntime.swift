import Foundation

public struct CloudAuthorizedTransport: Sendable {
    static let readTimeout: TimeInterval = 20

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

    public func send(_ original: URLRequest, timeout: TimeInterval? = nil, authorizationTimeout: TimeInterval? = nil) async throws -> TesseraeHTTPResponse {
        guard let url = original.url, url.scheme == issuer.scheme, url.host == issuer.host, url.port == issuer.port,
              url.path.hasPrefix(issuer.appending(path: "api/t").path + "/") else { throw ConnectionError.invalidIdentity }
        return try await sendAuthorized(original, timeout: timeout, authorizationTimeout: authorizationTimeout)
    }

    func sendAppleAccountLink(body: Data? = nil, timeout: TimeInterval?) async throws -> TesseraeHTTPResponse {
        guard issuer.scheme == "https", ["", "/"].contains(issuer.path) else { throw ConnectionError.invalidIdentity }
        let path = body == nil ? "auth/apple/web/app/status" : "auth/apple/web/app/start"
        var request = URLRequest(url: issuer.appending(path: path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await sendAuthorized(request, timeout: timeout, authorizationTimeout: nil)
    }

    private func sendAuthorized(_ original: URLRequest, timeout: TimeInterval?,
                                authorizationTimeout: TimeInterval?) async throws -> TesseraeHTTPResponse {
        let method = original.httpMethod ?? "GET"
        let isRead = method == "GET" || method == "HEAD"
        let timeout = timeout ?? (isRead ? Self.readTimeout : 10)
        let deadline = try CloudEntryDeadline(timeout: timeout)
        let sessionLimit = authorizationTimeout ?? (isRead ? 10 : timeout)
        var authorization = try await sessions.authorization(for: fence, timeout: deadline.remaining(limit: sessionLimit))
        var request = original
        request.cachePolicy = .reloadIgnoringLocalCacheData
        var canRetryNetwork = isRead
        var canRefreshAuthorization = isRead

        while true {
            request.setValue("Bearer \(authorization.token)", forHTTPHeaderField: "Authorization")
            let result: TesseraeHTTPResponse
            do {
                result = try await sendWithinBudget(request, deadline: deadline, canRetry: canRetryNetwork)
            } catch let error where canRetryNetwork && Self.isTransientNetworkError(error) {
                let retryDelay: TimeInterval = 0.25
                guard deadline.uptime - ProcessInfo.processInfo.systemUptime > retryDelay else { throw error }
                canRetryNetwork = false
                try await Task.sleep(for: .seconds(retryDelay))
                try await sessions.validate(fence, timeout: deadline.remaining(limit: sessionLimit))
                connectionLogger.notice("Retrying Cloud \(method, privacy: .public) after a temporary network error")
                continue
            }
            try await sessions.validate(fence, timeout: deadline.remaining(limit: sessionLimit))
            guard result.statusCode == 401, canRefreshAuthorization else { return result }
            canRefreshAuthorization = false
            authorization = try await sessions.authorization(for: fence, timeout: deadline.remaining(limit: sessionLimit),
                                                              rejecting: authorization)
        }
    }

    private func sendWithinBudget(_ request: URLRequest, deadline: CloudEntryDeadline,
                                  canRetry: Bool) async throws -> TesseraeHTTPResponse {
        let remaining = deadline.uptime - ProcessInfo.processInfo.systemUptime
        // Leave time for a retry if the first attempt stops receiving data.
        let idleTimeout = canRetry ? min(request.timeoutInterval, 15) : request.timeoutInterval
        var prepared = request
        prepared.timeoutInterval = max(0.001, min(idleTimeout, remaining))
        let frozen = prepared
        return try await boundedHTTP(timeout: remaining, operationName: "Cloud \(request.httpMethod ?? "GET")") {
            try await transport.send(frozen)
        }
    }

    private static func isTransientNetworkError(_ error: any Error) -> Bool {
        if (error as? ConnectionError) == .networkTimeout { return true }
        switch (error as? URLError)?.code {
        case .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed, .cannotConnectToHost: return true
        default: return false
        }
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

    public func cloudTransport(for id: ConnectionID, timeout: TimeInterval = 10) async throws -> CloudAuthorizedTransport {
        let deadline = try CloudEntryDeadline(timeout: timeout)
        guard let connection = try registry.connection(id), case let .cloud(issuer, _, _) = connection.identity,
              let fence = try await sessions.fence(for: id, timeout: deadline.remaining()) else { throw ConnectionError.invalidIdentity }
        try await sessions.validate(fence, timeout: deadline.remaining())
        _ = try deadline.remaining()
        return CloudAuthorizedTransport(issuer: issuer, fence: fence, sessions: sessions, transport: cloudHTTPTransport)
    }

    public func activate(_ id: ConnectionID) async throws {
        guard let fence = try await sessions.fence(for: id) else { throw ConnectionError.signedOut }
        try await sessions.commit(fence) { try registry.select(id) }
    }

    public func closeConnection(_ fence: ConnectionFence) async throws {
        try await sessions.close(fence)
        do {
            try await sessions.whileClosed(fence) {
                try registry.clearSelection(ifMatching: fence.connectionID)
            }
        } catch ConnectionError.sessionChanged {
            // A newer login owns the selection. Only this old grant's revocation remains.
        }
    }

    public func signOut(_ fence: ConnectionFence) async throws {
        try await closeConnection(fence)
        do { try await sessions.retryRevocations(for: fence.connectionID) }
        catch { throw ConnectionError.remoteRevocationUnconfirmed }
    }
}
