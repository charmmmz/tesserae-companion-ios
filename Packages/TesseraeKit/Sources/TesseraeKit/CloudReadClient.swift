import Foundation

public struct CloudReadClient: Sendable {
    public var fence: ConnectionFence { transport.fence }
    public var issuer: URL { transport.issuer }
    private let transport: CloudAuthorizedTransport

    private let timeout: TimeInterval
    public init(transport: CloudAuthorizedTransport, timeout: TimeInterval = 10) {
        self.transport = transport; self.timeout = timeout
    }

    public func bootstrap() async throws -> CloudBootstrap {
        let result: CloudBootstrap = try await read(["bootstrap"])
        try validate(result.account)
        return result
    }

    public func account() async throws -> CloudAccount {
        let result: CloudAccount = try await read(["me"])
        try validate(result)
        return result
    }

    public func devices() async throws -> [CloudDevice] {
        struct Response: Decodable { let devices: [CloudDevice] }
        let result: Response = try await read(["devices"])
        return result.devices
    }

    public func pages() async throws -> [CloudPage] {
        struct Response: Decodable { let pages: [CloudPage] }
        let result: Response = try await read(["pages"])
        return result.pages
    }

    public func devicePreview(id: String) async throws -> Data? {
        try await preview(["devices", id, "frame.png"])
    }

    public func pagePreview(id: String) async throws -> Data? {
        try await preview(["pages", id, "thumb.png"])
    }

    private func validate(_ account: CloudAccount) throws {
        guard account.issuer == issuer, account.id == account.tenant.id,
              !account.user.id.isEmpty, !account.tenant.id.isEmpty,
              ConnectionIdentity.cloud(issuer: issuer, userID: account.user.id,
                  tenantID: account.tenant.id).id == fence.connectionID,
              account.auth.resource == issuer.appending(path: "api/t").absoluteString,
              account.auth.scopes.contains("app:read"), !account.auth.grantID.isEmpty,
              account.auth.generation >= 0, ["owner", "member"].contains(account.role) else {
            throw CloudReadError.invalidResponse
        }
    }

    private func read<Value: Decodable>(_ components: [String]) async throws -> Value {
        let response = try await get(components, accept: "application/json")
        try requireSuccess(response)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            return try decoder.decode(Value.self, from: response.data)
        } catch { throw CloudReadError.invalidResponse }
    }

    private func preview(_ components: [String]) async throws -> Data? {
        let response = try await get(components, accept: "image/png")
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        guard response.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw CloudReadError.invalidResponse
        }
        return response.data
    }

    private func get(_ components: [String], accept: String) async throws -> TesseraeHTTPResponse {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudReadError.invalidResponse
        }
        let url = components.reduce(issuer.appending(path: "api/t")) { $0.appending(component: $1) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await transport.send(request, timeout: timeout, authorizationTimeout: min(10, timeout))
    }

    private func requireSuccess(_ response: TesseraeHTTPResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401: throw CloudReadError.unauthorized
        case 403:
            struct Refusal: Decodable { let reason: String? }
            let reason = try? JSONDecoder().decode(Refusal.self, from: response.data).reason
            throw CloudReadError.forbidden(reason: reason)
        case 402: throw CloudReadError.limitReached
        case 404: throw CloudReadError.notFound
        case 429:
            let value = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
            let seconds = value.flatMap(Double.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            throw CloudReadError.retryLater(retryAfter: seconds)
        case 503: throw CloudReadError.unavailable
        default: throw CloudReadError.unexpectedStatus(response.statusCode)
        }
    }
}
