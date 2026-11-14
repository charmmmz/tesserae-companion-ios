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
    var appleRequests: [AppleRequest] = []
    var requiresVerification = false
    var expectedAppleUser = "u1"
    var advertisesApple = true

    struct AppleRequest: Equatable {
        let path: String
        let method: String
        let body: [String: String]
    }

    func configureApple(verifyEmail: Bool = false, userID: String = "u1", advertised: Bool = true) {
        requiresVerification = verifyEmail
        expectedAppleUser = userID
        advertisesApple = advertised
    }
    func block(_ code: String, refused: Bool = false) {
        blocked.insert(code)
        if refused { refusals.insert(code) }
    }
    func release(_ code: String) { blocked.remove(code); continuations.removeValue(forKey: code)?.resume() }
    func count(_ code: String) -> Int { codes.filter { $0 == code }.count }
    func hasRequest(_ path: String) -> Bool { appleRequests.contains { $0.path == path } }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if let path = request.url?.path, path == "/auth/providers" || path.hasPrefix("/auth/apple/") {
            let body = try request.httpBody.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            appleRequests.append(AppleRequest(path: path, method: request.httpMethod ?? "", body: body))
            if blocked.contains(path) { await withCheckedContinuation { continuations[path] = $0 } }
            if refusals.contains(path) { return TesseraeHTTPResponse(data: Data(), statusCode: 503) }
            switch path {
            case "/auth/providers":
                return Self.json(advertisesApple ? #"{"apple_native":true}"# : #"{"providers":[]}"#)
            case "/auth/apple/start":
                return Self.json(#"{"attempt_id":"apple-attempt","nonce":"server-nonce"}"#)
            case "/auth/apple/complete":
                return requiresVerification ? Self.json(#"{"status":"verify_email"}"#) : consent(request)
            case "/auth/apple/email":
                return TesseraeHTTPResponse(data: Data(), statusCode: 204)
            case "/auth/apple/verify":
                return body["code"] == "123456" ? consent(request) : TesseraeHTTPResponse(data: Data(), statusCode: 400)
            default:
                break
            }
        }

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
            return TesseraeHTTPResponse(data: Self.token(code, resource: fields["resource"] ?? ""), statusCode: 200)
        }
        return TesseraeHTTPResponse(data: Data(), statusCode: 503)
    }
    private func consent(_ request: URLRequest) -> TesseraeHTTPResponse {
        let url = request.url!.deletingLastPathComponent().appending(path: "consent").absoluteString
        return Self.json("""
        {"status":"ready","user_id":"\(expectedAppleUser)","consent_url":"\(url)?ticket=opaque"}
        """)
    }

    private static func json(_ body: String) -> TesseraeHTTPResponse {
        TesseraeHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }

    static func token(_ code: String, resource: String) -> Data {
        Data("""
        {"access_token":"access-\(code)","token_type":"Bearer","expires_in":3600,"refresh_token":"refresh-\(code)","refresh_expires_in":86400,"scope":"app:read app:send app:refresh","resource":"\(resource)","grant_id":"grant-\(code)","generation":0,"user":{"id":"u1","email":"u@example.invalid"},"tenant":{"id":"t1","name":"Test"},"role":"member"}
        """.utf8)
    }
}

@MainActor
private final class LoginBrowser: CloudSignInBrowsing {
    var opened: [URL] = []
    var failToOpen = false
    func open(_ url: URL, completion: @escaping @MainActor (URL?, Error?) -> Void) throws {
        if failToOpen { throw CloudLoginError.unavailable }
        opened.append(url)
    }
    func cancel() {}
}

@MainActor
private final class LoginAppleAuthorization: CloudAppleAuthorizing {
    var nonce: String?
    var state: String?
    var wasCanceled = false
    func authorize(nonce: String, state: String) async throws -> CloudAppleCredential {
        self.nonce = nonce
        self.state = state
        return CloudAppleCredential(identityToken: "synthetic-id-token", authorizationCode: "synthetic-authorization-code")
    }
    func cancel() { wasCanceled = true }
}

@MainActor
final class CloudLoginLifecycleTests: XCTestCase {
    private let issuer = URL(string: "http://localhost:9000")!
    private let appleIssuer = URL(string: "https://staging.example.invalid:8443")!
    private struct Fixture {
        let host: ConnectionHost
        let local: AppModel
        let runtime: ConnectionRuntime
        let vault: CloudLoginVault
        let sessionsVault: LoginFaultVault
        let http: LoginHTTP
        let browser: LoginBrowser
        let apple: LoginAppleAuthorization
        let directory: URL
    }
    private func fixture(issuer: URL? = nil) -> Fixture {
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
        let browser = LoginBrowser()
        let apple = LoginAppleAuthorization()
        return Fixture(host: ConnectionHost(local: local, runtime: runtime, vault: vault,
            oauth: CloudOAuthClient(transport: http), issuer: issuer ?? self.issuer, browser: browser, appleAuthorization: apple),
            local: local, runtime: runtime, vault: vault, sessionsVault: sessionVault,
            http: http, browser: browser, apple: apple, directory: directory)
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

    func testAdvertisedAppleDirectLoginReusesPKCEAndCloudInstallation() async throws {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.host.checkAppleSignInAvailability()
        XCTAssertTrue(fixture.host.appleSignInAvailable)
        await fixture.host.beginAppleSignIn()

        let pending = try XCTUnwrap(fixture.vault.pending())
        XCTAssertEqual(pending.appleStage, .consent(userID: "u1"))
        XCTAssertEqual(fixture.apple.nonce, "server-nonce")
        XCTAssertEqual(fixture.apple.state, pending.state)
        XCTAssertEqual(fixture.browser.opened, [appleIssuer.appending(path: "auth/apple/consent").appending(queryItems: [.init(name: "ticket", value: "opaque")])])
        let requests = await fixture.http.appleRequests
        XCTAssertEqual(requests, [
            .init(path: "/auth/providers", method: "GET", body: [:]),
            .init(path: "/auth/apple/start", method: "POST", body: ["authorization_url": pending.authorizationURL.absoluteString]),
            .init(path: "/auth/apple/complete", method: "POST",
                  body: ["attempt_id": "apple-attempt", "identity_token": "synthetic-id-token", "authorization_code": "synthetic-authorization-code"])
        ])
        let callback = URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&code=apple-direct")!
        await fixture.host.receiveCloudCallback(callback)
        let expected = ConnectionIdentity.cloud(issuer: appleIssuer, userID: "u1", tenantID: "t1").id
        XCTAssertEqual(fixture.host.cloud?.fence.connectionID, expected)
        XCTAssertEqual(try fixture.runtime.registry.selectedID(), expected)
    }

    func testAppleVerificationReadsWireOutcomeAndKeepsGenericCodeFailure() async throws {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.configureApple(verifyEmail: true)
        await fixture.host.checkAppleSignInAvailability()
        await fixture.host.beginAppleSignIn()
        XCTAssertEqual(fixture.host.loginPhase, .appleEmail)
        XCTAssertTrue(fixture.browser.opened.isEmpty)

        await fixture.host.sendAppleEmailCode("  member@example.invalid  ")
        XCTAssertEqual(fixture.host.loginPhase, .appleCode)
        await fixture.host.verifyAppleEmailCode("12")
        await fixture.host.verifyAppleEmailCode("000000")
        XCTAssertEqual(fixture.host.loginPhase, .appleCode)
        XCTAssertEqual(fixture.host.loginError, CloudAppleSignInError.codeVerification.localizedDescription)
        XCTAssertTrue(fixture.browser.opened.isEmpty)

        await fixture.host.verifyAppleEmailCode("123456")
        XCTAssertEqual(fixture.host.loginPhase, .appleConsent)
        XCTAssertNil(fixture.host.loginError)
        XCTAssertEqual(fixture.browser.opened.count, 1)
        let requests = await fixture.http.appleRequests
        XCTAssertEqual(Array(requests.suffix(3)), [
            .init(path: "/auth/apple/email", method: "POST", body: ["attempt_id": "apple-attempt", "email": "member@example.invalid"]),
            .init(path: "/auth/apple/verify", method: "POST", body: ["attempt_id": "apple-attempt", "code": "000000"]),
            .init(path: "/auth/apple/verify", method: "POST", body: ["attempt_id": "apple-attempt", "code": "123456"])
        ])
    }

    func testEarlyCallbackCannotConsumeTheAttemptAndCanceledReadyCannotOpenConsent() async throws {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.host.checkAppleSignInAvailability()
        await fixture.http.block("/auth/apple/complete")
        let login = Task { await fixture.host.beginAppleSignIn() }
        let watchdog = ContinuousClock.now + .seconds(3)
        while !(await fixture.http.hasRequest("/auth/apple/complete")), ContinuousClock.now < watchdog {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedComplete = await fixture.http.hasRequest("/auth/apple/complete")
        XCTAssertTrue(reachedComplete)
        let pending = try XCTUnwrap(fixture.vault.pending())
        let early = URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&error=access_denied")!
        XCTAssertNil(try fixture.vault.claim(early, issuer: appleIssuer))
        await fixture.host.receiveCloudCallback(early)
        await fixture.host.receiveCloudCallback(URL(string: "https://other.example.invalid/fake")!)
        XCTAssertEqual(fixture.host.loginPhase, .appleCompleting)
        XCTAssertNil(fixture.host.loginError)
        XCTAssertFalse(try XCTUnwrap(fixture.vault.pending()).consumed)
        XCTAssertTrue(fixture.host.cancelCloudSignIn())
        await fixture.host.beginCloudSignIn()
        let next = try XCTUnwrap(fixture.vault.pending())
        await fixture.http.release("/auth/apple/complete")
        await login.value
        XCTAssertEqual(fixture.host.loginPhase, .browser)
        XCTAssertEqual(try fixture.vault.pending()?.id, next.id)
        XCTAssertEqual(fixture.browser.opened.count, 1)
        XCTAssertEqual(fixture.browser.opened.first?.path, "/oauth/authorize")
    }

    func testAppleConsentCannotInstallDifferentCloudUserAndRevokesGrant() async throws {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.configureApple(userID: "different")
        await fixture.host.checkAppleSignInAvailability()
        await fixture.host.beginAppleSignIn()
        let pending = try XCTUnwrap(fixture.vault.pending())
        let callback = URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&code=different-user")!
        await fixture.host.receiveCloudCallback(callback)
        XCTAssertNil(fixture.host.cloud)
        XCTAssertNil(try fixture.runtime.registry.selectedID())
        XCTAssertEqual(fixture.host.loginError, CloudLoginError.exchangeFailed.localizedDescription)
        let revoked = await fixture.http.revokedTokens
        XCTAssertEqual(revoked, ["refresh-different-user"])
        XCTAssertTrue(try fixture.vault.revocations().isEmpty)
    }

    func testAppleVerificationBrowserFailureClearsAttempt() async {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.configureApple(verifyEmail: true)
        await fixture.host.checkAppleSignInAvailability()
        await fixture.host.beginAppleSignIn()
        await fixture.host.sendAppleEmailCode("member@example.invalid")
        fixture.browser.failToOpen = true
        await fixture.host.verifyAppleEmailCode("123456")
        XCTAssertEqual(fixture.host.loginPhase, .idle)
        XCTAssertEqual(fixture.host.loginError, CloudLoginError.exchangeFailed.localizedDescription)
        XCTAssertNil(try fixture.vault.pending())
    }

    func testAppleRequiresExplicitCapabilityAndHTTPSIssuer() async {
        let absent = fixture(issuer: appleIssuer)
        await absent.http.configureApple(advertised: false)
        await absent.host.checkAppleSignInAvailability()
        await absent.host.beginAppleSignIn()
        XCTAssertFalse(absent.host.appleSignInAvailable)
        let advertisedRequests = await absent.http.appleRequests
        XCTAssertEqual(advertisedRequests.map(\.path), ["/auth/providers"])

        let http = fixture()
        await http.host.checkAppleSignInAvailability()
        XCTAssertFalse(http.host.appleSignInAvailable)
        let insecureRequests = await http.http.appleRequests
        XCTAssertTrue(insecureRequests.isEmpty)
    }

    func testAppleBetaButtonIsReadyBeforeDiscoveryAndServerRefusalKeepsEmailSignIn() async throws {
        try XCTSkipUnless(AppConfiguration.isAppleLoginBeta)
        let issuer = try XCTUnwrap(AppConfiguration.bundledCloudIssuer)
        try XCTSkipIf(issuer.host == AppConfiguration.defaultCloudIssuer.host)
        try XCTSkipUnless(CloudOAuthClient.supportsAppleSignIn(issuer: issuer))
        let fixture = fixture(issuer: issuer)
        let startPath = "/auth/apple/start"
        await fixture.http.configureApple(advertised: false)

        XCTAssertTrue(fixture.host.appleSignInAvailable)
        await fixture.host.checkAppleSignInAvailability()
        let discoveryRequests = await fixture.http.appleRequests
        XCTAssertTrue(discoveryRequests.isEmpty)
        XCTAssertTrue(fixture.host.appleSignInAvailable)

        await fixture.http.block(startPath, refused: true)
        let login = Task { await fixture.host.beginAppleSignIn() }
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await fixture.http.hasRequest(startPath)), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let reachedStart = await fixture.http.hasRequest(startPath)
        XCTAssertTrue(reachedStart)
        XCTAssertEqual(fixture.host.loginPhase, .applePreparing)
        XCTAssertNil(fixture.apple.nonce)
        await fixture.http.release(startPath)
        await login.value

        XCTAssertEqual(fixture.host.loginPhase, .idle)
        XCTAssertNil(try fixture.vault.pending())
        XCTAssertNil(fixture.apple.nonce)
        XCTAssertEqual(fixture.host.loginError, CloudAppleSignInError.startUnavailable.localizedDescription)
        XCTAssertTrue(fixture.host.appleSignInAvailable)
        let requests = await fixture.http.appleRequests
        XCTAssertEqual(requests.map(\.path), [startPath])

        await fixture.host.beginCloudSignIn()
        XCTAssertEqual(fixture.host.loginPhase, .browser)
        XCTAssertEqual(fixture.browser.opened.last?.path, "/oauth/authorize")
    }

    func testAppleBrowserConsentRejectsChangedOriginPathAndQuery() {
        let authority = "https://staging.example.invalid:8443"
        let path = "/auth/apple/consent"
        for invalid in [
            "/auth/apple/consent?ticket=opaque",
            "http://staging.example.invalid:8443\(path)?ticket=opaque",
            "https://staging.example.invalid\(path)?ticket=opaque",
            "https://untrusted.example.invalid:8443\(path)?ticket=opaque",
            "https://name@staging.example.invalid:8443\(path)?ticket=opaque",
            "\(authority)/auth/apple/%63onsent?ticket=opaque",
            "\(authority)/oauth/authorize?ticket=opaque",
            "\(authority)\(path)?ticket=opaque&ticket=other",
            "\(authority)\(path)?ticket=opaque&redirect=https://example.invalid",
            "\(authority)\(path)?ticket=",
            "\(authority)\(path)?ticket=opaque#fragment"
        ] {
            XCTAssertNil(CloudOAuthClient.appleConsentURL(invalid, issuer: appleIssuer), invalid)
        }
        XCTAssertNotNil(CloudOAuthClient.appleConsentURL("\(authority)\(path)?ticket=opaque-_123", issuer: appleIssuer))
    }

}
