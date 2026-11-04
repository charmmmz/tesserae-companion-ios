import Foundation
import Security

public protocol SessionVault: Sendable {
    func read(_ id: ConnectionID) throws -> Data?
    func write(_ data: Data, for id: ConnectionID) throws
}

public struct KeychainSessionVault: SessionVault {
    private let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service + ".sessions.v2"
        self.accessGroup = accessGroup
    }

    public func read(_ id: ConnectionID) throws -> Data? {
        var query = query(id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw CredentialStoreError.invalidTokenEncoding }
        return data
    }

    public func write(_ data: Data, for id: ConnectionID) throws {
        var query = query(id)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecSuccess else { throw CredentialStoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func query(_ id: ConnectionID) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: id.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

public struct SharedSessionStore: Sendable {
    private let directory: URL
    private let vault: any SessionVault
    private let oauth: CloudOAuthHTTP

    public init(directory: URL, vault: any SessionVault,
                transport: any TesseraeHTTPTransporting = URLSessionTesseraeTransport()) {
        self.directory = directory
        self.vault = vault
        oauth = CloudOAuthHTTP(transport: transport)
    }

    public func installLocal(instance: TesseraeInstance, token: String) async throws -> ConnectionFence {
        guard !token.isEmpty else { throw ConnectionError.invalidTokenResponse }
        let identity = try ConnectionIdentity.local(instance)
        return try await install(identity: identity, state: .local(token))
    }

    func importLocal(instance: TesseraeInstance, token: String) async throws -> ConnectionFence {
        let identity = try ConnectionIdentity.local(instance)
        return try await transaction(identity.id) { old in
            if let old { return (nil, old.fence) }
            let imported = CredentialEnvelope(identity: identity, epoch: UUID(), revision: 0,
                state: .local(token), revocations: [])
            return (imported, imported.fence)
        }
    }

    public func installCloud(issuer: URL, response: CloudTokenResponse) async throws -> ConnectionFence {
        let issuer = try ConnectionIdentity.canonicalService(issuer)
        let tokens = try CloudTokens(issuer: issuer, response: response)
        let identity = ConnectionIdentity.cloud(issuer: issuer, userID: response.user.id, tenantID: response.tenant.id)
        return try await install(identity: identity, state: .cloud(tokens))
    }

    private func install(identity: ConnectionIdentity, state: CredentialState) async throws -> ConnectionFence {
        try await transaction(identity.id) { old in
            var revocations = old?.revocations ?? []
            if let old {
                switch old.state {
                case let .local(token):
                    if case let .selfHosted(service, _) = old.identity {
                        revocations.append(PendingRevocation(id: UUID(), issuer: service, token: token, isLocal: true))
                    }
                case let .cloud(tokens), let .refreshing(tokens, _):
                    if case let .cloud(next) = state, next.response.grantID == tokens.response.grantID {
                        throw ConnectionError.invalidTokenResponse
                    }
                    revocations.append(PendingRevocation(id: UUID(), issuer: tokens.issuer, token: tokens.response.refreshToken))
                default: break
                }
            }
            let envelope = CredentialEnvelope(identity: identity, epoch: UUID(), revision: 0,
                state: state, revocations: revocations)
            return (envelope, envelope.fence)
        }
    }

    public func fence(for id: ConnectionID) async throws -> ConnectionFence? {
        try await transaction(id) { envelope in (nil, envelope?.fence) }
    }

    public func validate(_ fence: ConnectionFence, timeout: TimeInterval = 10) async throws {
        try await transaction(fence.connectionID, timeout: timeout) { envelope in
            let current = try checked(envelope, fence: fence)
            if case let .closed(reason) = current.state { throw reason.error }
            return (nil, ())
        }
    }

    func commit<T: Sendable>(_ fence: ConnectionFence, _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await transaction(fence.connectionID) { envelope in
            let current = try checked(envelope, fence: fence)
            if case let .closed(reason) = current.state { throw reason.error }
            return (nil, try operation())
        }
    }

    public func authorization(for fence: ConnectionFence, timeout: TimeInterval = 10,
                              rejecting rejected: ConnectionAuthorization? = nil) async throws -> ConnectionAuthorization {
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ConnectionError.coordinationTimeout }
            let decision = try await transaction(fence.connectionID, timeout: remaining) { envelope -> (CredentialEnvelope?, AuthorizationDecision) in
                var current = try checked(envelope, fence: fence)
                switch current.state {
                case let .local(token):
                    return (nil, .ready(ConnectionAuthorization(fence: fence, revision: current.revision, token: token)))
                case let .cloud(tokens):
                    if tokens.accessExpiresAt.timeIntervalSinceNow > 30,
                       rejected?.revision != current.revision || rejected?.fence != fence {
                        return (nil, .ready(ConnectionAuthorization(fence: fence, revision: current.revision,
                                                                  token: tokens.response.accessToken)))
                    }
                    guard tokens.refreshExpiresAt > Date() else {
                        scheduleRevocation(&current, tokens: tokens, reason: .authorizationRequired)
                        return (current, .failed(.authorizationRequired))
                    }
                    let pending = PendingRotation(id: UUID(), revision: current.revision,
                                                  deadline: Date().addingTimeInterval(remaining))
                    current.state = .refreshing(tokens, pending)
                    return (current, .rotate(tokens, pending))
                case let .refreshing(tokens, pending):
                    if pending.deadline <= Date() {
                        scheduleRevocation(&current, tokens: tokens, reason: .rotationOutcomeUnknown)
                        return (current, .failed(.rotationOutcomeUnknown))
                    }
                    return (nil, .wait)
                case let .closed(reason): return (nil, .failed(reason.error))
                }
            }
            switch decision {
            case let .ready(value): return value
            case let .failed(error): throw error
            case .wait: try await Task.sleep(for: .milliseconds(25))
            case let .rotate(tokens, pending):
                do {
                    let response = try await oauth.refresh(tokens, timeout: deadline - ProcessInfo.processInfo.systemUptime)
                    let next = try CloudTokens(issuer: tokens.issuer, response: response)
                    return try await transaction(fence.connectionID, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) { envelope in
                        var current = try checked(envelope, fence: fence)
                        guard case let .refreshing(_, active) = current.state, active.id == pending.id, active.revision == pending.revision,
                              current.revision == pending.revision, active.deadline > Date() else {
                            throw ConnectionError.sessionChanged
                        }
                        current.revision += 1
                        current.state = .cloud(next)
                        return (current, ConnectionAuthorization(fence: fence, revision: current.revision,
                                                                 token: response.accessToken))
                    }
                } catch {
                    let reason: ConnectionClosure = (error as? ConnectionError) == .authorizationRequired
                        ? .authorizationRequired : .rotationOutcomeUnknown
                    try await transaction(fence.connectionID, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) { envelope in
                        guard var current = envelope, current.fence == fence,
                              case let .refreshing(_, active) = current.state, active.id == pending.id, active.revision == pending.revision,
                              current.revision == pending.revision else { return (nil, ()) }
                        scheduleRevocation(&current, tokens: tokens, reason: reason)
                        return (current, ())
                    }
                    throw reason.error
                }
            }
        }
    }

    public func close(_ fence: ConnectionFence) async throws {
        try await transaction(fence.connectionID) { envelope in
            var current = try checked(envelope, fence: fence)
            switch current.state {
            case let .local(token):
                if case let .selfHosted(service, _) = current.identity {
                    current.revocations.append(PendingRevocation(id: UUID(), issuer: service, token: token, isLocal: true))
                }
                current.state = .closed(.signedOut)
            case let .cloud(tokens), let .refreshing(tokens, _): scheduleRevocation(&current, tokens: tokens, reason: .signedOut)
            default: current.state = .closed(.signedOut)
            }
            return (current, ())
        }
    }

    func whileClosed(_ fence: ConnectionFence, _ operation: @escaping @Sendable () throws -> Void) async throws {
        try await transaction(fence.connectionID) { envelope in
            let current = try checked(envelope, fence: fence)
            guard case .closed(.signedOut) = current.state else { throw ConnectionError.sessionChanged }
            try operation()
            return (nil, ())
        }
    }

    public func signOut(_ fence: ConnectionFence) async throws {
        try await close(fence)
        do { try await retryRevocations(for: fence.connectionID) }
        catch { throw ConnectionError.remoteRevocationUnconfirmed }
    }

    public func retryRevocations(for id: ConnectionID, timeout: TimeInterval = 10) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let pending = try await transaction(id) { envelope in (nil, envelope?.revocations ?? []) }
        // Each call attempts each captured grant once. Failed records remain protected for a later explicit retry.
        for record in pending {
            try await oauth.revoke(record, timeout: deadline - ProcessInfo.processInfo.systemUptime)
            try await transaction(id, timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) { envelope in
                guard var current = envelope else { return (nil, ()) }
                current.revocations.removeAll { $0.id == record.id }
                return (current, ())
            }
        }
    }

    private func transaction<T: Sendable>(_ id: ConnectionID, timeout: TimeInterval = 10,
        _ operation: @escaping @Sendable (CredentialEnvelope?) throws -> (CredentialEnvelope?, T)) async throws -> T {
        let vault = vault
        let lock = SharedFileLock(url: directory.appending(path: "SessionLocks/\(id.fileComponent).lock"))
        let task = Task.detached(priority: .utility) {
            try lock.withLock(timeout: timeout) {
                let data = try vault.read(id)
                let envelope = try data.map { try ConnectionCoding.decoder().decode(CredentialEnvelope.self, from: $0) }
                guard envelope == nil || envelope?.identity.id == id else { throw ConnectionError.invalidIdentity }
                let (updated, value) = try operation(envelope)
                if let updated { try vault.write(ConnectionCoding.encoder().encode(updated), for: id) }
                return value
            }
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

private enum AuthorizationDecision: Sendable {
    case ready(ConnectionAuthorization), rotate(CloudTokens, PendingRotation), wait, failed(ConnectionError)
}

private func checked(_ envelope: CredentialEnvelope?, fence: ConnectionFence) throws -> CredentialEnvelope {
    guard let envelope else { throw ConnectionError.signedOut }
    guard envelope.fence == fence else { throw ConnectionError.sessionChanged }
    return envelope
}

private func scheduleRevocation(_ envelope: inout CredentialEnvelope, tokens: CloudTokens, reason: ConnectionClosure) {
    envelope.revocations.append(PendingRevocation(id: UUID(), issuer: tokens.issuer, token: tokens.response.refreshToken))
    envelope.state = .closed(reason)
}

private extension ConnectionClosure {
    var error: ConnectionError {
        switch self {
        case .signedOut: .signedOut
        case .authorizationRequired: .authorizationRequired
        case .rotationOutcomeUnknown: .rotationOutcomeUnknown
        }
    }
}
