import Foundation
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

private final class LoginFaultVault: SessionVault, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ConnectionID: Data] = [:]
    var failWrite = false
    func read(_ id: ConnectionID) throws -> Data? { lock.withLock { values[id] } }
    func write(_ data: Data, for id: ConnectionID) throws {
        try lock.withLock {
            if failWrite { throw ConnectionError.unavailable }
            values[id] = data
        }
    }
}

private actor LoginHTTP: TesseraeHTTPTransporting {
    var blocked: Set<String> = []
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    var refusals: Set<String> = []
    var codes: [String] = []
    var revokedTokens: [String] = []
    func block(_ code: String, refused: Bool = false) {
        blocked.insert(code)
        if refused { refusals.insert(code) }
    }
    func release(_ code: String) { blocked.remove(code); continuations.removeValue(forKey: code)?.resume() }
    func count(_ code: String) -> Int { codes.filter { $0 == code }.count }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        var form = URLComponents()
        form.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        let fields = Dictionary(uniqueKeysWithValues: (form.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if request.url?.path == "/oauth/revoke" {
            revokedTokens.append(fields["token"] ?? "")
            return TesseraeHTTPResponse(data: Data(), statusCode: 200)
        }
        if request.url?.path == "/oauth/token" {
            let code = fields["code"] ?? ""
            codes.append(code)
            if blocked.contains(code) { await withCheckedContinuation { continuations[code] = $0 } }
            if refusals.contains(code) { return TesseraeHTTPResponse(data: Data(), statusCode: 400) }
            return TesseraeHTTPResponse(data: Self.token(code), statusCode: 200)
        }
        return TesseraeHTTPResponse(data: Data(), statusCode: 503)
    }
    static func token(_ code: String) -> Data {
        Data("""
        {"access_token":"access-\(code)","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-\(code)","refresh_expires_in":86400,"scope":"app:read app:send app:refresh","resource":"http://localhost:9000/api/t","grant_id":"grant-\(code)","generation":0,"user":{"id":"u1","email":"u@example.invalid"},"tenant":{"id":"t1","name":"Test"},"role":"member"}
        """.utf8)
    }
}

@MainActor
final class CloudLoginLifecycleTests: XCTestCase {
    private let issuer = URL(string: "http://localhost:9000")!
    private struct Fixture {
        let host: ConnectionHost
        let local: AppModel
        let runtime: ConnectionRuntime
        let vault: CloudLoginVault
        let sessionsVault: LoginFaultVault
        let http: LoginHTTP
        let directory: URL
    }
    private func fixture() -> Fixture {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = LoginHTTP(); let sessionVault = LoginFaultVault()
        let sessions = SharedSessionStore(directory: directory, vault: sessionVault, transport: http)
        let credentials = InMemoryCredentialStore()
        let runtime = ConnectionRuntime(directory: directory, identity: TesseraeClientIdentity(appVersion: "test", installationID: "test"),
            credentials: credentials, sessions: sessions, legacy: InMemoryCompanionStateStore(), isPrimary: true, transport: http)
        let local = AppModel(liveClient: runtime.bootstrapClient(), connectionRuntime: runtime,
            demoClient: MockTesseraeClient(latency: .zero), credentials: credentials, stateStore: runtime.stateStore,
            sendPreferences: InMemoryCompanionSendPreferencesStore(), shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(), activityThumbnails: InMemoryActivityThumbnailStore(), discovery: StaticDiscoveryService(results: []))
        let vault = CloudLoginVault(directory: directory, service: "test.cloud.lifecycle.\(UUID())")
        return Fixture(host: ConnectionHost(local: local, runtime: runtime, vault: vault,
            oauth: CloudOAuthClient(transport: http), issuer: issuer), local: local, runtime: runtime,
            vault: vault, sessionsVault: sessionVault, http: http, directory: directory)
    }
    private func pending(_ fixture: Fixture, code: String) throws -> URL {
        let pending = try PendingCloudLogin(issuer: issuer)
        try fixture.vault.replace(pending)
        return URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&code=\(code)")!
    }
    private func wait(_ http: LoginHTTP, code: String) async throws {
        for _ in 0..<1000 {
            if await http.count(code) > 0 { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("No exchange for synthetic code")
    }
    func testDuplicateCallbackExchangesOnceAndBootstrapFailureKeepsValidSession() async throws {
        let fixture = fixture(); let url = try pending(fixture, code: "one")
        async let first: Void = fixture.host.receiveCloudCallback(url)
        async let second: Void = fixture.host.receiveCloudCallback(url)
        _ = await (first, second)
        let count = await fixture.http.count("one")
        XCTAssertEqual(count, 1)
        let cloud = try XCTUnwrap(fixture.host.cloud)
        XCTAssertNil(cloud.snapshot); XCTAssertNotNil(cloud.problem)
        XCTAssertFalse(cloud.needsSignIn)
        XCTAssertEqual(try fixture.runtime.registry.selectedID(), cloud.fence.connectionID)
        try await fixture.runtime.sessions.validate(cloud.fence)
    }
    func testOldExchangeFailureDoesNotCancelNewExchange() async throws {
        let fixture = fixture()
        await fixture.http.block("old", refused: true)
        let oldURL = try pending(fixture, code: "old")
        let old = Task { await fixture.host.receiveCloudCallback(oldURL) }
        try await wait(fixture.http, code: "old")
        XCTAssertTrue(fixture.host.cancelCloudSignIn())
        await fixture.http.block("new")
        let newURL = try pending(fixture, code: "new")
        let new = Task { await fixture.host.receiveCloudCallback(newURL) }
        try await wait(fixture.http, code: "new")
        await fixture.http.release("old"); await old.value
        XCTAssertEqual(fixture.host.loginPhase, .exchanging)
        XCTAssertNil(fixture.host.loginError)
        await fixture.http.release("new"); await new.value
        XCTAssertNotNil(fixture.host.cloud)
        XCTAssertEqual(fixture.host.loginPhase, .idle)
    }
    func testLateCanceledSuccessOnlyRevokesItsOwnGrant() async throws {
        let fixture = fixture()
        await fixture.http.block("old")
        let oldURL = try pending(fixture, code: "old")
        let old = Task { await fixture.host.receiveCloudCallback(oldURL) }
        try await wait(fixture.http, code: "old")
        XCTAssertTrue(fixture.host.cancelCloudSignIn())
        await fixture.host.receiveCloudCallback(try pending(fixture, code: "new"))
        let newFence = try XCTUnwrap(fixture.host.cloud?.fence)
        await fixture.http.release("old"); await old.value
        XCTAssertEqual(fixture.host.cloud?.fence, newFence)
        let authorization = try await fixture.runtime.sessions.authorization(for: newFence)
        XCTAssertEqual(authorization.token, "access-new")
        let revoked = await fixture.http.revokedTokens
        XCTAssertEqual(revoked, ["refresh-old"])
        XCTAssertTrue(try fixture.vault.revocations().isEmpty)
    }
    func testDeniedReturnsIdleAndWrongStateKeepsCurrentAttempt() async throws {
        let fixture = fixture()
        let pending = try PendingCloudLogin(issuer: issuer)
        try fixture.vault.replace(pending)
        await fixture.host.receiveCloudCallback(URL(string: PendingCloudLogin.callback + "?state=bad&code=one")!)
        XCTAssertFalse(try fixture.vault.pending()!.consumed)
        await fixture.host.receiveCloudCallback(URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&error=access_denied")!)
        XCTAssertEqual(fixture.host.loginPhase, .idle)
        XCTAssertNil(try fixture.vault.pending())
        await fixture.host.receiveCloudCallback(try self.pending(fixture, code: "again"))
        XCTAssertNotNil(fixture.host.cloud)
        XCTAssertNil(fixture.host.loginError)
    }
    func testFailedInstallPreservesDemoAndRevokesUninstalledResponse() async throws {
        let fixture = fixture()
        await fixture.host.connectDemo()
        fixture.sessionsVault.failWrite = true
        await fixture.host.receiveCloudCallback(try pending(fixture, code: "failure"))
        XCTAssertNil(fixture.host.cloud)
        XCTAssertEqual(fixture.local.connectionMode, .demo)
        XCTAssertNil(try fixture.runtime.registry.selectedID())
        XCTAssertNotNil(fixture.host.loginError)
        let revoked = await fixture.http.revokedTokens
        XCTAssertEqual(revoked, ["refresh-failure"])
    }
    func testDescriptorFailureClosesOnlyNewlyInstalledFence() async throws {
        let fixture = fixture()
        try FileManager.default.createDirectory(at: fixture.runtime.registry.directory.appending(path: "registry.lock"), withIntermediateDirectories: true)
        await fixture.host.receiveCloudCallback(try pending(fixture, code: "descriptor"))
        XCTAssertNil(fixture.host.cloud)
        XCTAssertNotNil(fixture.host.loginError)
        let id = ConnectionIdentity.cloud(issuer: issuer, userID: "u1", tenantID: "t1").id
        let captured = try await fixture.runtime.sessions.fence(for: id)
        let fence = try XCTUnwrap(captured)
        do {
            _ = try await fixture.runtime.sessions.authorization(for: fence)
            XCTFail("Failed installation must not remain usable")
        } catch { XCTAssertEqual(error as? ConnectionError, .signedOut) }
    }
}
