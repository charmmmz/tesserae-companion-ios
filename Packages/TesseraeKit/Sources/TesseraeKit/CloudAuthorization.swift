import Foundation

public struct CloudTokenResponse: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public struct User: Codable, Hashable, Sendable { public let id: String; public let email: String }
    public struct Tenant: Codable, Hashable, Sendable { public let id: String; public let name: String }
    public let accessToken: String
    public let tokenType: String
    public let expiresIn: Double
    public let refreshToken: String
    public let refreshExpiresIn: Double
    public let scope: String
    public let resource: String
    public let grantID: String
    public let generation: Int
    public let user: User
    public let tenant: Tenant
    public let role: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", tokenType = "token_type", expiresIn = "expires_in"
        case refreshToken = "refresh_token", refreshExpiresIn = "refresh_expires_in"
        case grantID = "grant_id", generation, scope, resource, user, tenant, role
    }
    public var description: String { "CloudTokenResponse(<redacted>)" }
    public var debugDescription: String { description }

    func validate(issuer: URL) throws {
        guard tokenType == "Bearer", !accessToken.isEmpty, !refreshToken.isEmpty,
              expiresIn.isFinite, expiresIn > 0, refreshExpiresIn.isFinite, refreshExpiresIn > 0,
              !grantID.isEmpty, generation >= 0, !user.id.isEmpty, !tenant.id.isEmpty,
              resource == issuer.appending(path: "api/t").absoluteString,
              !scopes.isEmpty, scopes.isSubset(of: ["app:read", "app:send", "app:refresh"]) else {
            throw ConnectionError.invalidTokenResponse
        }
    }
    var scopes: Set<String> { Set(scope.split(separator: " ").map(String.init)) }
}

struct CloudTokens: Codable, Sendable {
    let issuer: URL
    let response: CloudTokenResponse
    let accessExpiresAt: Date
    let refreshExpiresAt: Date

    init(issuer: URL, response: CloudTokenResponse, now: Date = Date()) throws {
        try response.validate(issuer: issuer)
        self.issuer = issuer
        self.response = response
        accessExpiresAt = now.addingTimeInterval(response.expiresIn)
        refreshExpiresAt = now.addingTimeInterval(response.refreshExpiresIn)
    }
}

struct PendingRotation: Codable, Equatable, Sendable {
    let id: UUID
    let revision: Int
    let deadline: Date
}

struct PendingRevocation: Codable, Sendable {
    let id: UUID
    let issuer: URL
    let token: String
    var isLocal: Bool? = nil
}

enum CredentialState: Codable, Sendable {
    case local(String)
    case cloud(CloudTokens)
    case refreshing(CloudTokens, PendingRotation)
    case closed(ConnectionClosure)
}

public enum ConnectionClosure: String, Codable, Sendable {
    case signedOut, authorizationRequired, rotationOutcomeUnknown
}

struct CredentialEnvelope: Codable, Sendable {
    let identity: ConnectionIdentity
    var epoch: UUID
    var revision: Int
    var state: CredentialState
    var revocations: [PendingRevocation]

    var fence: ConnectionFence { ConnectionFence(connectionID: identity.id, epoch: epoch) }
}

public struct ConnectionAuthorization: Sendable, CustomStringConvertible {
    public let fence: ConnectionFence
    public let revision: Int
    public let token: String
    public var description: String { "ConnectionAuthorization(<redacted>)" }
}

struct CloudOAuthHTTP: Sendable {
    let transport: any TesseraeHTTPTransporting

    func refresh(_ tokens: CloudTokens, timeout: TimeInterval) async throws -> CloudTokenResponse {
        let fields = ["grant_type": "refresh_token", "client_id": "tesserae-companion",
                      "resource": tokens.response.resource, "refresh_token": tokens.response.refreshToken]
        let prepared = request(issuer: tokens.issuer, path: "oauth/token", fields: fields, timeout: timeout)
        let result = try await boundedHTTP(timeout: timeout) { try await transport.send(prepared) }
        if result.statusCode == 400 {
            struct Refusal: Decodable { let error: String }
            if (try? JSONDecoder().decode(Refusal.self, from: result.data).error) == "invalid_grant" {
                throw ConnectionError.authorizationRequired
            }
        }
        guard result.statusCode == 200 else { throw ConnectionError.rotationOutcomeUnknown }
        guard let response = try? JSONDecoder().decode(CloudTokenResponse.self, from: result.data) else {
            throw ConnectionError.invalidTokenResponse
        }
        try response.validate(issuer: tokens.issuer)
        guard response.grantID == tokens.response.grantID,
              response.generation == tokens.response.generation + 1,
              response.user.id == tokens.response.user.id, response.tenant.id == tokens.response.tenant.id,
              response.resource == tokens.response.resource, response.scopes == tokens.response.scopes else {
            throw ConnectionError.invalidTokenResponse
        }
        return response
    }

    func revoke(_ pending: PendingRevocation, timeout: TimeInterval) async throws {
        let prepared: URLRequest
        if pending.isLocal == true {
            var local = URLRequest(url: pending.issuer.appending(path: "api/app/v1/session"))
            local.httpMethod = "DELETE"
            local.timeoutInterval = max(0.001, min(8, timeout))
            local.setValue("Bearer \(pending.token)", forHTTPHeaderField: "Authorization")
            prepared = local
        } else {
            prepared = request(issuer: pending.issuer, path: "oauth/revoke",
                fields: ["token": pending.token, "client_id": "tesserae-companion"], timeout: timeout)
        }
        let result = try await boundedHTTP(timeout: timeout) { try await transport.send(prepared) }
        let accepted = pending.isLocal == true ? [204, 401] : [200]
        guard accepted.contains(result.statusCode) else { throw ConnectionError.unavailable }
    }

    private func request(issuer: URL, path: String, fields: [String: String], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: issuer.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = max(0.001, min(8, timeout))
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }
}

private final class HTTPCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TesseraeHTTPResponse, any Error>?
    private var outcome: Result<TesseraeHTTPResponse, any Error>?
    private var tasks: [Task<Void, Never>] = []

    func attach(_ continuation: CheckedContinuation<TesseraeHTTPResponse, any Error>) {
        lock.lock()
        let finished = outcome
        if finished == nil { self.continuation = continuation }
        lock.unlock()
        if let finished { continuation.resume(with: finished) }
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        let finished = outcome != nil
        if !finished { tasks.append(task) }
        lock.unlock()
        if finished { task.cancel() }
    }

    func finish(_ result: Result<TesseraeHTTPResponse, any Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        let captured = continuation
        continuation = nil
        let running = tasks
        tasks = []
        lock.unlock()
        captured?.resume(with: result)
        running.forEach { $0.cancel() }
    }
}

func boundedHTTP(timeout: TimeInterval,
                 operation: @escaping @Sendable () async throws -> TesseraeHTTPResponse) async throws -> TesseraeHTTPResponse {
    guard timeout > 0 else { throw ConnectionError.coordinationTimeout }
    let completion = HTTPCompletion()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            completion.attach(continuation)
            let request = Task {
                do {
                    try Task.checkCancellation()
                    completion.finish(.success(try await operation()))
                } catch { completion.finish(.failure(error)) }
            }
            completion.track(request)
            let timer = Task {
                do {
                    try await Task.sleep(for: .seconds(timeout))
                    completion.finish(.failure(ConnectionError.coordinationTimeout))
                } catch { }
            }
            completion.track(timer)
        }
    } onCancel: {
        completion.finish(.failure(CancellationError()))
    }
}
