import Foundation
import Testing
@testable import TesseraeKit

private actor ProtectedResourceFixture: TesseraeHTTPTransporting {
    var status = 200
    var hold = false
    var count = 0
    var refreshCount = 0
    var observedTimeout: TimeInterval = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func configure(status: Int = 200, hold: Bool = false) { self.status = status; self.hold = hold }
    func unblock() { continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if request.url?.path == "/oauth/token" {
            refreshCount += 1
            return TesseraeHTTPResponse(data: try tokenFixture(generation: 1, expires: 3600), statusCode: 200)
        }
        count += 1
        observedTimeout = request.timeoutInterval
        if hold { await withCheckedContinuation { continuation = $0 } }
        return TesseraeHTTPResponse(data: Data(), statusCode: status)
    }
}

@Suite struct CloudAuthorizedTransportTests {
    private func fixture() async throws -> (SharedSessionStore, ConnectionFence, CloudAuthorizedTransport, ProtectedResourceFixture) {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = ProtectedResourceFixture()
        let store = SharedSessionStore(directory: directory, vault: TestSessionVault(directory: directory.appending(path: "vault")), transport: http)
        let issuer = URL(string: "http://localhost:9000")!
        let fence = try await store.installCloud(issuer: issuer,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600)))
        return (store, fence, CloudAuthorizedTransport(issuer: issuer, fence: fence, sessions: store, transport: http), http)
    }

    @Test func writeUnauthorizedIsReturnedWithoutRefreshOrReplay() async throws {
        let (_, _, client, http) = try await fixture()
        await http.configure(status: 401)
        var request = URLRequest(url: URL(string: "http://localhost:9000/api/t/send/image")!)
        request.httpMethod = "POST"
        let result = try await client.send(request)
        #expect(result.statusCode == 401)
        #expect(await http.count == 1)
        #expect(await http.refreshCount == 0)
    }

    @Test func protectedReadUsesTotalBudget() async throws {
        let (_, _, client, http) = try await fixture()
        await http.configure(hold: true)
        let started = ContinuousClock.now
        let request = URLRequest(url: URL(string: "http://localhost:9000/api/t/bootstrap")!)
        await #expect(throws: ConnectionError.coordinationTimeout) { try await client.send(request, timeout: 0.08) }
        #expect(started.duration(to: .now) < .seconds(1))
        #expect(await http.observedTimeout <= 0.08)
        await http.unblock()
    }

    @Test func lateSuccessFromOldLoginNeverReachesConsumer() async throws {
        let (store, _, client, http) = try await fixture()
        await http.configure(hold: true)
        let operation = Task {
            try await client.send(URLRequest(url: URL(string: "http://localhost:9000/api/t/bootstrap")!))
        }
        for _ in 0..<1000 {
            if await http.count > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await http.count > 0)
        let fresh = try await store.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600, grant: "g2")))
        await http.unblock()
        await #expect(throws: ConnectionError.sessionChanged) { try await operation.value }
        #expect(try await store.authorization(for: fresh).revision == 0)
    }
}
