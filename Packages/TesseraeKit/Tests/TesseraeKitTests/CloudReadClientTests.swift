import Foundation
import Testing
@testable import TesseraeKit

private actor CloudReadFixture: TesseraeHTTPTransporting {
    var response: TesseraeHTTPResponse
    var requests: [URLRequest] = []

    init(_ response: TesseraeHTTPResponse) { self.response = response }
    func set(_ response: TesseraeHTTPResponse) { self.response = response }

    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        requests.append(request)
        if request.url?.path == "/oauth/token" {
            return TesseraeHTTPResponse(data: try tokenFixture(generation: 1, expires: 3600), statusCode: 200)
        }
        return response
    }
}

@Suite struct CloudReadClientTests {
    private func bootstrapData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Contracts/Fixtures/cloud-bootstrap.json"))
    }

    private func fixture(_ response: TesseraeHTTPResponse) async throws -> (CloudReadClient, CloudReadFixture) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = CloudReadFixture(response)
        let sessions = SharedSessionStore(directory: directory,
            vault: TestSessionVault(directory: directory.appending(path: "vault")), transport: http)
        let issuer = URL(string: "http://localhost:9000")!
        let fence = try await sessions.installCloud(issuer: issuer,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600)))
        return (CloudReadClient(transport: CloudAuthorizedTransport(issuer: issuer,
            fence: fence, sessions: sessions, transport: http)), http)
    }

    @Test func bootstrapKeepsCloudSemanticsAndLoadsAllListsWithOneRead() async throws {
        let (client, http) = try await fixture(TesseraeHTTPResponse(data: bootstrapData(), statusCode: 200))
        let result = try await client.bootstrap()
        #expect(result.account.user.id == "u1")
        #expect(result.account.tenant.id == "t1")
        #expect(result.account.role == "member")
        #expect(result.account.features["connectors"] == true)
        #expect(result.account.limits["renders_per_day"] == 200)
        #expect(result.account.limits.keys.contains("future_unlimited_limit"))
        #expect(result.account.limits["future_unlimited_limit"]! == nil)
        #expect(result.account.usage.rendersChargedToday == 1)
        #expect(result.devices[0].panel.width == 800)
        #expect(result.devices[0].panel.gamut == "spectra6")
        #expect(result.devices[0].batteryPercent == 81)
        #expect(result.devices[0].frame?.renderedAt == Date(timeIntervalSince1970: 1793769900))
        #expect(result.devices[1].frame == nil)
        #expect(result.devices[1].batteryPercent == nil)
        #expect(result.pages[1].deviceID == nil)
        let requests = await http.requests
        #expect(requests.count == 1)
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].url?.path == "/api/t/bootstrap")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
    }

    @Test(arguments: ["user", "tenant", "issuer", "resource", "scope", "role"])
    func rejectsAccountThatDoesNotMatchAuthorizedConnection(field: String) async throws {
        var body = try #require(JSONSerialization.jsonObject(with: bootstrapData()) as? [String: Any])
        var account = try #require(body["me"] as? [String: Any])
        switch field {
        case "user": account["user"] = ["id": "other-user", "email": "other@example.invalid"]
        case "tenant": account["tenant"] = ["id": "other-tenant", "name": "Other"]
        case "issuer": account["issuer"] = "https://other.example.invalid"
        case "resource":
            var auth = try #require(account["auth"] as? [String: Any])
            auth["resource"] = "http://localhost:9000/mcp"
            account["auth"] = auth
        case "scope":
            var auth = try #require(account["auth"] as? [String: Any])
            auth["scopes"] = ["mcp"]
            account["auth"] = auth
        default: account["role"] = "administrator"
        }
        body["me"] = account
        let (client, _) = try await fixture(TesseraeHTTPResponse(
            data: JSONSerialization.data(withJSONObject: body), statusCode: 200))
        await #expect(throws: CloudReadError.invalidResponse) { try await client.bootstrap() }
    }

    @Test func previewNeverRendersAndMissingImageRemainsMissing() async throws {
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let (client, http) = try await fixture(TesseraeHTTPResponse(data: png, statusCode: 200))
        #expect(try await client.devicePreview(id: "same-device") == png)
        await http.set(TesseraeHTTPResponse(data: Data(), statusCode: 404))
        #expect(try await client.pagePreview(id: "no-preview-page") == nil)
        let requests = await http.requests
        #expect(requests.map { $0.url!.path } == ["/api/t/devices/same-device/frame.png", "/api/t/pages/no-preview-page/thumb.png"])
        #expect(requests.allSatisfy { $0.httpMethod == "GET" && $0.cachePolicy == .reloadIgnoringLocalCacheData })
    }

    @Test func nonImageSuccessIsRejected() async throws {
        let (client, _) = try await fixture(TesseraeHTTPResponse(data: Data("<html>login</html>".utf8), statusCode: 200))
        await #expect(throws: CloudReadError.invalidResponse) { try await client.pagePreview(id: "a") }
    }

    @Test(arguments: [401, 403, 402, 429, 503, 404, 500])
    func readFailureRetainsStatusMeaning(status: Int) async throws {
        let response = TesseraeHTTPResponse(data: Data(#"{"reason":"membership_removed"}"#.utf8),
            statusCode: status, headers: ["Retry-After": "17"])
        let (client, http) = try await fixture(response)
        let expected: CloudReadError = switch status {
        case 401: .unauthorized
        case 403: .forbidden(reason: "membership_removed")
        case 402: .limitReached
        case 429: .retryLater(retryAfter: 17)
        case 503: .unavailable
        case 404: .notFound
        default: .unexpectedStatus(status)
        }
        await #expect(throws: expected) { try await client.pages() }
        let requests = await http.requests
        #expect(requests.allSatisfy { $0.httpMethod == "GET" || $0.url?.path == "/oauth/token" })
        #expect(requests.filter { $0.url?.path == "/oauth/token" }.count == (status == 401 ? 1 : 0))
    }
}
