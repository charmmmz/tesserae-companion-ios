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

    private func fixture(
        _ response: TesseraeHTTPResponse,
        issuer: URL = URL(string: "http://localhost:9000")!
    ) async throws -> (CloudReadClient, CloudReadFixture) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = CloudReadFixture(response)
        let sessions = SharedSessionStore(directory: directory,
            vault: TestSessionVault(directory: directory.appending(path: "vault")), transport: http)
        let token = try tokenFixture(expires: 3600, resource: issuer.appending(path: "api/t").absoluteString)
        let fence = try await sessions.installCloud(issuer: issuer,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: token))
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
        #expect(requests[0].timeoutInterval > 10)
        #expect(requests[0].timeoutInterval <= 20)
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

    @Test func createsDevicePairingWhenCloudReturnsCreated() async throws {
        let issuer = try #require(URL(string: "https://cloud.example.invalid"))
        let code = "abcdefghijklmnopqrstuvwxYZ0123-_"
        let body = try JSONEncoder().encode(["code": code])
        let (client, http) = try await fixture(.init(data: body, statusCode: 201), issuer: issuer)

        let pairing = try await client.createDevicePairing(mac: "02:01:02:03:04:05")

        #expect(pairing == code)
        let requests = await http.requests
        try #require(requests.count == 1)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[0].url?.path == "/api/t/app/device-pairing")
        #expect(requests[0].timeoutInterval <= 10)
    }

    @Test func looksUpADeviceWithTheCloudWorkspaceGrantAndNormalizedMAC() async throws {
        let (client, http) = try await fixture(.init(data: Data(#"{"device_id":"picpak-cloud"}"#.utf8), statusCode: 200))
        #expect(try await client.lookupDisplay(mac: "02-01-02-03-04-05") == "picpak-cloud")
        #expect(try await client.lookupDisplay(mac: "03:04:05") == nil)
        let requests = await http.requests
        try #require(requests.count == 1)
        let request = requests[0]
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/t/app/devices/lookup")
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        let body = try #require(request.httpBody)
        #expect(try JSONDecoder().decode([String: String].self, from: body) == ["mac": "02:01:02:03:04:05"])
    }

    @Test func explicitlyNullLookupIsDistinctFromAnUnavailableOrInvalidResponse() async throws {
        let (client, http) = try await fixture(.init(data: Data(#"{"device_id":null}"#.utf8), statusCode: 200))
        #expect(try await client.lookupDisplay(mac: "02:01:02:03:04:05") == nil)
        await http.set(.init(data: Data(), statusCode: 404))
        await #expect(throws: CloudReadError.notFound) {
            try await client.lookupDisplay(mac: "02:01:02:03:04:05")
        }
        await http.set(.init(data: Data("{}".utf8), statusCode: 200))
        await #expect(throws: CloudReadError.invalidResponse) {
            try await client.lookupDisplay(mac: "02:01:02:03:04:05")
        }
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

    @Test func upcomingUsesTheSelectedDisplayAndFetchesTheExactStagedRevision() async throws {
        let body = Data("""
        {"upcoming":{"dashboard":{"id":"weather","name":"Weather"},"estimated_switch_at":1793769900,
          "preview":{"revision":"next+1&2","rendered_at":1793769800,"url":"https://elsewhere.invalid/image"}}}
        """.utf8)
        let (client, http) = try await fixture(.init(data: body, statusCode: 200))
        let upcoming = try #require(await client.deviceUpcoming(id: "panel A"))
        let staged = try #require(upcoming.preview)
        #expect(upcoming.dashboard.id == "weather")
        #expect(upcoming.dashboard.name == "Weather")
        #expect(upcoming.estimatedSwitchAt == Date(timeIntervalSince1970: 1793769900))
        #expect(staged.renderedAt == Date(timeIntervalSince1970: 1793769800))

        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        await http.set(.init(data: png, statusCode: 200))
        #expect(try await client.nextDevicePreview(id: "panel A", revision: staged.revision) == png)
        await http.set(.init(data: Data(), statusCode: 404))
        #expect(try await client.nextDevicePreview(id: "panel A", revision: staged.revision) == nil)

        let requests = await http.requests
        #expect(requests.map { $0.url?.path } == [
            "/api/t/devices/panel A/upcoming", "/api/t/devices/panel A/next-frame.png", "/api/t/devices/panel A/next-frame.png"
        ])
        #expect(requests.allSatisfy {
            $0.httpMethod == "GET" && $0.url?.host == "localhost" && $0.cachePolicy == .reloadIgnoringLocalCacheData
                && $0.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true
        })
        let imageURL = try #require(requests.last?.url)
        #expect(URLComponents(url: imageURL, resolvingAgainstBaseURL: false)?.queryItems ==
            [URLQueryItem(name: "revision", value: "next+1&2")])
    }

    @Test func upcomingWithoutAnEstimateOrFrameIsDistinctFromNoUpcomingDashboard() async throws {
        let body = Data("""
        {"upcoming":{"dashboard":{"id":"weather","name":"Weather"},"estimated_switch_at":null,"preview":null}}
        """.utf8)
        let (client, http) = try await fixture(.init(data: body, statusCode: 200))
        let upcoming = try #require(await client.deviceUpcoming(id: "display"))
        #expect(upcoming.dashboard.name == "Weather")
        #expect(upcoming.estimatedSwitchAt == nil)
        #expect(upcoming.preview == nil)
        await http.set(.init(data: Data(#"{"upcoming":null}"#.utf8), statusCode: 200))
        #expect(try await client.deviceUpcoming(id: "display") == nil)
    }

    @Test func nonImageSuccessIsRejected() async throws {
        let (client, _) = try await fixture(TesseraeHTTPResponse(data: Data("<html>login</html>".utf8), statusCode: 200))
        await #expect(throws: CloudReadError.invalidResponse) { try await client.pagePreview(id: "a") }
    }

    @Test(arguments: [201, 401, 403, 402, 429, 503, 404, 500])
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
    @Test func revokedMembershipReadHasActionableSystemError() async throws {
        let (client, http) = try await fixture(.init(data: Data("{\"reason\":\"membership_removed\"}".utf8), statusCode: 403))
        do {
            _ = try await client.bootstrap()
            Issue.record("Removed membership must refuse the read")
        } catch let error as CloudReadError {
            #expect(error == .forbidden(reason: "membership_removed"))
            #expect((error as NSError).localizedDescription == "Access to this Cloud tenant is unavailable. Choose another connection or sign in again.")
        }
        #expect(await http.requests.count == 1)
    }

}
