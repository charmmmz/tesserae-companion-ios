import Foundation

public enum CloudAppleAccountLinkStart: Sendable {
    case authorization(url: URL, expiresIn: TimeInterval)
    case alreadyLinked
}

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

    public func appleAccountLinked() async throws -> Bool? {
        guard issuer.scheme == "https", ["", "/"].contains(issuer.path) else { return nil }
        let response = try await transport.sendAppleAccountLink(timeout: timeout)
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        struct Status: Decodable { let linked: Bool }
        guard let status = try? JSONDecoder().decode(Status.self, from: response.data) else {
            throw CloudReadError.invalidResponse
        }
        return status.linked
    }

    public func startAppleAccountLink(state: String) async throws -> CloudAppleAccountLinkStart {
        let data = try JSONEncoder().encode(["state": state])
        let response = try await transport.sendAppleAccountLink(body: data, timeout: timeout)
        if response.statusCode == 409 { return .alreadyLinked }
        try requireSuccess(response)
        struct Start: Decodable {
            let authorization_url: String
            let expires_in: TimeInterval
        }
        guard let start = try? JSONDecoder().decode(Start.self, from: response.data),
              (0...900).contains(start.expires_in), start.expires_in > 0,
              let parts = URLComponents(string: start.authorization_url),
              parts.scheme == "https", parts.host?.lowercased() == issuer.host?.lowercased(),
              (parts.port ?? 443) == (issuer.port ?? 443), parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.percentEncodedPath == "/auth/apple/web/app/link",
              let query = parts.queryItems, query.count == 1, query[0].name == "ticket",
              let ticket = query[0].value, ticket.utf8.count == 43,
              ticket.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              parts.percentEncodedQuery == "ticket=\(ticket)", let url = parts.url else {
            throw CloudReadError.invalidResponse
        }
        return .authorization(url: url, expiresIn: start.expires_in)
    }

    public func createDevicePairing(mac: String) async throws -> String {
        guard issuer.scheme == "https",
              let mac = DeviceHardwareIdentity.normalizedMAC(mac) else { throw CloudReadError.invalidResponse }
        var request = URLRequest(url: issuer.appending(path: "api/t/app/device-pairing"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["mac": mac])
        let response = try await transport.send(request, timeout: timeout)
        try requireSuccess(response, expectedStatus: 201)
        struct Pairing: Decodable { let code: String }
        guard let pairing = try? JSONDecoder().decode(Pairing.self, from: response.data),
              pairing.code.utf8.count == 32,
              pairing.code.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0)
                      || (97...122).contains($0) || $0 == 45 || $0 == 95
              }) else { throw CloudReadError.invalidResponse }
        return pairing.code
    }

    public func devices() async throws -> [CloudDevice] {
        struct Response: Decodable { let devices: [CloudDevice] }
        let result: Response = try await read(["devices"])
        return result.devices
    }

    public func lookupDisplay(mac: String) async throws -> String? {
        guard let mac = DeviceHardwareIdentity.normalizedMAC(mac) else { return nil }
        var request = URLRequest(url: issuer.appending(path: "api/t/app/devices/lookup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceLookupRequest(mac: mac))
        let response = try await transport.send(request, timeout: timeout, authorizationTimeout: min(10, timeout))
        try requireSuccess(response)

        struct Lookup: Decodable {
            let deviceID: String?
            enum CodingKeys: String, CodingKey { case deviceID = "device_id" }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                deviceID = try values.decode(String?.self, forKey: .deviceID)
            }
        }
        guard let lookup = try? JSONDecoder().decode(Lookup.self, from: response.data),
              lookup.deviceID?.isEmpty != true else { throw CloudReadError.invalidResponse }
        return lookup.deviceID
    }

    public func pages() async throws -> [CloudPage] {
        struct Response: Decodable { let pages: [CloudPage] }
        let result: Response = try await read(["pages"])
        return result.pages
    }

    public func devicePreview(id: String) async throws -> Data? {
        try await preview(["devices", id, "frame.png"])
    }

    public func deviceUpcoming(id: String) async throws -> CloudDisplayUpcoming? {
        struct Response: Decodable { let upcoming: CloudDisplayUpcoming? }
        let result: Response = try await read(["devices", id, "upcoming"])
        return result.upcoming
    }

    public func nextDevicePreview(id: String, revision: String) async throws -> Data? {
        guard !revision.isEmpty else { throw CloudReadError.invalidResponse }
        return try await preview(["devices", id, "next-frame.png"],
            query: [URLQueryItem(name: "revision", value: revision)])
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

    private func preview(_ components: [String], query: [URLQueryItem] = []) async throws -> Data? {
        let response = try await get(components, accept: "image/png", query: query)
        if response.statusCode == 404 { return nil }
        try requireSuccess(response)
        guard response.data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) else {
            throw CloudReadError.invalidResponse
        }
        return response.data
    }

    private func get(_ components: [String], accept: String, query: [URLQueryItem] = []) async throws -> TesseraeHTTPResponse {
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudReadError.invalidResponse
        }
        let url = components.reduce(issuer.appending(path: "api/t")) { $0.appending(component: $1) }
        var request = URLRequest(url: query.isEmpty ? url : url.appending(queryItems: query))
        request.httpMethod = "GET"
        request.setValue(accept, forHTTPHeaderField: "Accept")
        return try await transport.send(request, timeout: timeout, authorizationTimeout: min(10, timeout))
    }

    private func requireSuccess(_ response: TesseraeHTTPResponse, expectedStatus: Int = 200) throws {
        if response.statusCode == expectedStatus { return }
        switch response.statusCode {
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
