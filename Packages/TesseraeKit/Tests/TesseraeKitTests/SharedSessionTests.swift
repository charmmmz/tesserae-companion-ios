import Foundation
import Testing
@testable import TesseraeKit

struct TestSessionVault: SessionVault {
    let directory: URL
    func read(_ id: ConnectionID) throws -> Data? {
        let url = directory.appending(path: id.fileComponent)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func write(_ data: Data, for id: ConnectionID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: id.fileComponent), options: .atomic)
    }
}

private actor OAuthFixture: TesseraeHTTPTransporting {
    var refreshCount = 0
    var revokeCount = 0
    var loseResponse = false
    var release: CheckedContinuation<Void, Never>?
    var hold = false

    func configure(lose: Bool = false, hold: Bool = false) { loseResponse = lose; self.hold = hold }
    func unblock() { release?.resume(); release = nil }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if request.url!.path == "/oauth/revoke" {
            revokeCount += 1
            return TesseraeHTTPResponse(data: Data(), statusCode: 200)
        }
        refreshCount += 1
        if hold { await withCheckedContinuation { release = $0 } }
        if loseResponse { throw URLError(.networkConnectionLost) }
        return TesseraeHTTPResponse(data: try tokenFixture(generation: 1, expires: 3600), statusCode: 200)
    }
}

func tokenFixture(user: String = "u1", tenant: String = "t1", generation: Int = 0,
                  expires: Double = 1, grant: String = "g1") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["access_token": "synthetic-access-\(generation)",
        "token_type": "Bearer", "expires_in": expires, "refresh_token": "synthetic-refresh-\(generation)",
        "refresh_expires_in": 1000, "scope": "app:read app:send app:refresh",
        "resource": "http://localhost:9000/api/t", "grant_id": grant, "generation": generation,
        "user": ["id": user, "email": "synthetic@example.invalid"],
        "tenant": ["id": tenant, "name": "Synthetic"], "role": "member"])
}

private func sessionFixture() throws -> (SharedSessionStore, OAuthFixture) {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    let transport = OAuthFixture()
    return (SharedSessionStore(directory: directory, vault: TestSessionVault(directory: directory.appending(path: "vault")),
                               transport: transport), transport)
}

@Suite struct SharedSessionTests {
    @Test func identitySeparatesUsersTenantsAndServices() throws {
        let url = URL(string: "http://localhost:9000")!
        let a = ConnectionIdentity.cloud(issuer: url, userID: "a", tenantID: "t")
        #expect(a.id != ConnectionIdentity.cloud(issuer: url, userID: "b", tenantID: "t").id)
        #expect(a.id != ConnectionIdentity.cloud(issuer: url, userID: "a", tenantID: "u").id)
        #expect(try ConnectionIdentity.canonicalService(URL(string: "https://EXAMPLE.com:443/base/?q=x#z")!)
                == URL(string: "https://example.com/base")!)
    }

    @Test func ordinaryExpiryRotatesAndDoesNotChangeEpoch() async throws {
        let (store, http) = try sessionFixture()
        let token = try JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture())
        let fence = try await store.installCloud(issuer: URL(string: "http://localhost:9000")!, response: token)
        async let a = store.authorization(for: fence)
        async let b = store.authorization(for: fence)
        async let c = store.authorization(for: fence)
        let values = try await [a, b, c]
        #expect(values.allSatisfy { $0.fence == fence && $0.revision == 1 })
        #expect(await http.refreshCount == 1)
    }

    @Test func lostResponseRequiresAuthorizationAndNeverReplaysRefresh() async throws {
        let (store, http) = try sessionFixture()
        await http.configure(lose: true)
        let token = try JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture())
        let fence = try await store.installCloud(issuer: URL(string: "http://localhost:9000")!, response: token)
        await #expect(throws: ConnectionError.rotationOutcomeUnknown) { try await store.authorization(for: fence) }
        await #expect(throws: ConnectionError.rotationOutcomeUnknown) { try await store.authorization(for: fence) }
        #expect(await http.refreshCount == 1)
        try await store.retryRevocations(for: fence.connectionID)
        #expect(await http.revokeCount == 1)
    }

    @Test func oldResponseCannotOverwriteRelogin() async throws {
        let (store, http) = try sessionFixture()
        await http.configure(hold: true)
        let token = try JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture())
        let issuer = URL(string: "http://localhost:9000")!
        let old = try await store.installCloud(issuer: issuer, response: token)
        let inFlight = Task { try await store.authorization(for: old) }
        for _ in 0..<1000 {
            if await http.refreshCount > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await http.refreshCount > 0)
        try await store.signOut(old)
        let newToken = try JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600))
        let fresh = try await store.installCloud(issuer: issuer, response: newToken)
        await http.unblock()
        _ = await inFlight.result
        #expect(fresh.epoch != old.epoch)
        #expect(try await store.authorization(for: fresh).revision == 0)
        await #expect(throws: ConnectionError.sessionChanged) { try await store.validate(old) }
    }

    @Test func directReplacementRetainsOnlyOldGrantRevocation() async throws {
        let (store, http) = try sessionFixture()
        await http.configure(hold: true)
        let issuer = URL(string: "http://localhost:9000")!
        let old = try await store.installCloud(issuer: issuer,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture()))
        let oldRequest = Task { try await store.authorization(for: old) }
        for _ in 0..<1000 {
            if await http.refreshCount > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await http.refreshCount > 0)
        let fresh = try await store.installCloud(issuer: issuer,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600, grant: "g2")))
        await http.unblock()
        _ = await oldRequest.result
        try await store.retryRevocations(for: fresh.connectionID)
        #expect(await http.revokeCount == 1)
        #expect(try await store.authorization(for: fresh).revision == 0)
    }

    @Test func refreshHonorsShortTotalBudgetEvenWithUncooperativeTransport() async throws {
        let (store, http) = try sessionFixture()
        await http.configure(hold: true)
        let fence = try await store.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture()))
        let started = ContinuousClock.now
        await #expect(throws: ConnectionError.rotationOutcomeUnknown) {
            try await store.authorization(for: fence, timeout: 0.08)
        }
        #expect(started.duration(to: .now) < .seconds(1))
        await http.unblock()
        await #expect(throws: ConnectionError.rotationOutcomeUnknown) { try await store.authorization(for: fence) }
        #expect(await http.refreshCount == 1)
    }
}
