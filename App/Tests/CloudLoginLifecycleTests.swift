import AuthenticationServices
import CryptoKit
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
    var advertisesAppleWeb = false
    var discoveryIssuer: URL?
    var accountLinkStatus: Int = 404
    var accountLinked = false
    var accountLinkStartStatus: Int = 200
    var accountLinkURL: String?
    private var refusesNextAppleEmail = false

    struct AppleRequest: Equatable {
        let path: String
        let method: String
        let body: [String: String]
        let authorization: String?

        init(path: String, method: String, body: [String: String], authorization: String? = nil) {
            self.path = path
            self.method = method
            self.body = body
            self.authorization = authorization
        }
    }

    func configureApple(verifyEmail: Bool = false, userID: String = "u1", advertised: Bool = true, webAdvertised: Bool = false) {
        requiresVerification = verifyEmail
        expectedAppleUser = userID
        advertisesApple = advertised
        advertisesAppleWeb = webAdvertised
    }
    func block(_ code: String, refused: Bool = false) {
        blocked.insert(code)
        if refused { refusals.insert(code) }
    }
    func release(_ code: String) { blocked.remove(code); continuations.removeValue(forKey: code)?.resume() }
    func refuseNextAppleEmailRequest() { refusesNextAppleEmail = true }
    func count(_ code: String) -> Int { codes.filter { $0 == code }.count }
    func hasRequest(_ path: String) -> Bool { appleRequests.contains { $0.path == path } }
    private var advertisesDevicePairing = false

    func advertiseOptionalScopes(issuer: URL, devicePairing: Bool = false) {
        discoveryIssuer = issuer
        advertisesDevicePairing = devicePairing
    }
    func configureAccountLink(status: Int = 200, linked: Bool = false, startStatus: Int = 200, startURL: String? = nil) {
        accountLinkStatus = status
        accountLinked = linked
        accountLinkStartStatus = startStatus
        accountLinkURL = startURL
    }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if request.url?.path == "/.well-known/oauth-authorization-server", let discoveryIssuer {
            let pairing = advertisesDevicePairing ? #","app:device:pair""# : ""
            return Self.json(#"{"issuer":"\#(discoveryIssuer.absoluteString)","scopes_supported":["app:read","app:apple:link"\#(pairing)]}"#)
        }
        if let path = request.url?.path, path == "/auth/providers" || path.hasPrefix("/auth/apple/") {
            let body = try request.httpBody.map { try JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
            appleRequests.append(AppleRequest(path: path, method: request.httpMethod ?? "", body: body,
                authorization: request.value(forHTTPHeaderField: "Authorization")))
            if blocked.contains(path) { await withCheckedContinuation { continuations[path] = $0 } }
            if refusals.contains(path) { return TesseraeHTTPResponse(data: Data(), statusCode: 503) }
            switch path {
            case "/auth/providers":
                if advertisesAppleWeb {
                    return Self.json(#"{"apple_web":true,"apple_native":\#(advertisesApple)}"#)
                }
                return Self.json(advertisesApple ? #"{"apple_native":true}"# : #"{"providers":[]}"#)
            case "/auth/apple/start":
                return Self.json(#"{"attempt_id":"apple-attempt","nonce":"server-nonce"}"#)
            case "/auth/apple/complete":
                return requiresVerification ? Self.json(#"{"status":"verify_email"}"#) : consent(request)
            case "/auth/apple/email":
                if refusesNextAppleEmail {
                    refusesNextAppleEmail = false
                    return TesseraeHTTPResponse(data: Data(), statusCode: 429)
                }
                return TesseraeHTTPResponse(data: Data(), statusCode: 204)
            case "/auth/apple/verify":
                return body["code"] == "123456" ? consent(request) : TesseraeHTTPResponse(data: Data(), statusCode: 400)
            case "/auth/apple/web/app/status":
                guard accountLinkStatus == 200 else { return TesseraeHTTPResponse(data: Data(), statusCode: accountLinkStatus) }
                return Self.json(#"{"linked":\#(accountLinked)}"#)
            case "/auth/apple/web/app/start":
                if accountLinkStartStatus == 409 { accountLinked = true }
                guard accountLinkStartStatus == 200 else { return TesseraeHTTPResponse(data: Data(), statusCode: accountLinkStartStatus) }
                let ticket = String(repeating: "t", count: 43)
                let url = accountLinkURL ?? request.url!.deletingLastPathComponent().appending(path: "link").absoluteString + "?ticket=\(ticket)"
                return Self.json(#"{"authorization_url":"\#(url)","expires_in":600}"#)
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
    private var completion: (@MainActor (URL?, Error?) -> Void)?
    func open(_ url: URL, completion: @escaping @MainActor (URL?, Error?) -> Void) throws {
        if failToOpen { throw CloudLoginError.unavailable }
        opened.append(url)
        self.completion = completion
    }
    func cancel() {}
    func finish(_ url: URL?, error: Error? = nil) {
        let callback = completion
        completion = nil
        callback?(url, error)
    }
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

    func testNewCloudLoginRequestsOptionalScopesOnlyFromTheCurrentIssuer() async {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.advertiseOptionalScopes(issuer: URL(string: "https://different.example.invalid")!, devicePairing: true)
        await fixture.host.beginCloudSignIn()
        XCTAssertEqual(fixture.browser.opened.last.flatMap(loginScope), PendingCloudLogin.scopes)
        fixture.host.cancelCloudSignIn()

        await fixture.http.advertiseOptionalScopes(issuer: appleIssuer)
        await fixture.host.beginCloudSignIn()
        XCTAssertEqual(fixture.browser.opened.last.flatMap(loginScope),
            "\(PendingCloudLogin.scopes) \(CloudTokenResponse.appleAccountLinkScope)")
        fixture.host.cancelCloudSignIn()

        await fixture.http.advertiseOptionalScopes(issuer: appleIssuer, devicePairing: true)
        await fixture.host.beginCloudSignIn()
        let scopes = fixture.browser.opened.last.flatMap(loginScope)
        XCTAssertEqual(scopes, "\(PendingCloudLogin.scopes) \(CloudTokenResponse.appleAccountLinkScope) \(CloudTokenResponse.devicePairingScope)")
        fixture.host.cancelCloudSignIn()
    }

    func testAppleLinkUsesTheExistingGrantAndConfirmsSuccessWithCloud() async throws {
        let fixture = fixture(issuer: appleIssuer)
        let client = try await appleAccountClient(fixture)
        let model = CloudAppleAccountLinkModel(browser: fixture.browser)
        await fixture.http.configureAccountLink()
        await model.check(client, isCurrent: { true })
        XCTAssertEqual(model.isLinked, false)

        await model.link(client, isCurrent: { true })
        let requested = await fixture.http.appleRequests
        XCTAssertEqual(requested.map(\.path), ["/auth/apple/web/app/status", "/auth/apple/web/app/start"])
        XCTAssertTrue(requested.allSatisfy { $0.authorization == "Bearer access-existing" })
        XCTAssertEqual(requested.last?.method, "POST")
        let state = try XCTUnwrap(requested.last?.body["state"])
        XCTAssertEqual(state.count, 43)
        let opened = try XCTUnwrap(fixture.browser.opened.last)
        XCTAssertEqual(opened.path, "/auth/apple/web/app/link")
        XCTAssertEqual(opened.port, 8443)

        await fixture.http.configureAccountLink(linked: true)
        fixture.browser.finish(linkCallback(state: state))
        try await waitForAppleAccountLink(model)
        XCTAssertEqual(model.isLinked, true)
        XCTAssertNil(model.problem)
        let refreshed = await fixture.http.appleRequests
        XCTAssertEqual(refreshed.last?.path, "/auth/apple/web/app/status")
    }

    func testAppleLinkRejectsAnUntrustedURLOrCallbackAndNeverAssumesLinked() async throws {
        let fixture = fixture(issuer: appleIssuer)
        let client = try await appleAccountClient(fixture)
        let model = CloudAppleAccountLinkModel(browser: fixture.browser)
        await fixture.http.configureAccountLink(startURL: "https://other.example.invalid/auth/apple/web/app/link?ticket=\(String(repeating: "t", count: 43))")
        await model.check(client, isCurrent: { true })
        await model.link(client, isCurrent: { true })
        XCTAssertTrue(fixture.browser.opened.isEmpty)
        XCTAssertNotNil(model.problem)

        await fixture.http.configureAccountLink()
        await model.link(client, isCurrent: { true })
        fixture.browser.finish(linkCallback(state: "wrong-state"))
        XCTAssertEqual(model.isLinked, false)
        XCTAssertNotNil(model.problem)
        let first = await fixture.http.appleRequests
        XCTAssertEqual(first.filter { $0.path.hasSuffix("/status") }.count, 1)

        await model.link(client, isCurrent: { true })
        let started = await fixture.http.appleRequests
        fixture.browser.finish(linkCallback(state: try XCTUnwrap(started.last?.body["state"])))
        try await waitForAppleAccountLink(model)
        XCTAssertEqual(model.isLinked, false)
        XCTAssertNotNil(model.problem)
    }

    func testAppleLinkCancellationAndLateCallbackDoNotChangeTheCurrentAccount() async throws {
        let fixture = fixture(issuer: appleIssuer)
        let client = try await appleAccountClient(fixture)
        let model = CloudAppleAccountLinkModel(browser: fixture.browser)
        // An older Cloud deployment keeps the settings row hidden.
        await model.check(client, isCurrent: { true })
        XCTAssertNil(model.isLinked)
        XCTAssertNil(model.problem)

        await fixture.http.configureAccountLink()
        await model.check(client, isCurrent: { true })
        await model.link(client, isCurrent: { true })
        fixture.browser.finish(nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        XCTAssertEqual(model.isLinked, false)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.problem)

        await model.link(client, isCurrent: { true })
        let requests = await fixture.http.appleRequests
        let state = try XCTUnwrap(requests.last?.body["state"])
        model.reset()
        fixture.browser.finish(linkCallback(state: state))
        XCTAssertNil(model.isLinked)
        XCTAssertNil(model.problem)
        let after = await fixture.http.appleRequests
        XCTAssertEqual(after, requests)
    }

    func testAppleLinkConflictReadsTheCurrentStatusWithoutOpeningABrowser() async throws {
        let fixture = fixture(issuer: appleIssuer)
        let client = try await appleAccountClient(fixture)
        let model = CloudAppleAccountLinkModel(browser: fixture.browser)
        await fixture.http.configureAccountLink(startStatus: 409)
        await model.check(client, isCurrent: { true })
        await model.link(client, isCurrent: { true })
        XCTAssertEqual(model.isLinked, true)
        XCTAssertTrue(fixture.browser.opened.isEmpty)
        XCTAssertNil(model.problem)
    }

    private func loginScope(_ url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "scope" }?.value
    }

    private func appleAccountClient(_ fixture: Fixture) async throws -> CloudReadClient {
        let data = LoginHTTP.token("existing", resource: appleIssuer.appending(path: "api/t").absoluteString)
        let response = try JSONDecoder().decode(CloudTokenResponse.self, from: data)
        let fence = try await fixture.runtime.installCloud(issuer: appleIssuer, response: response)
        return try await CloudReadClient(transport: fixture.runtime.cloudTransport(for: fence.connectionID))
    }

    private func linkCallback(state: String) -> URL {
        URL(string: "\(PendingCloudLogin.callbackScheme):/apple/link/callback?state=\(state)&result=linked")!
    }

    private func waitForAppleAccountLink(_ model: CloudAppleAccountLinkModel) async throws {
        for _ in 0..<100 where model.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isBusy)
    }

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

    func testSignOutConfirmationCannotCloseAReplacementCloudSession() async throws {
        let fixture = fixture()
        await fixture.host.receiveCloudCallback(try pending(fixture, code: "original"))
        let original = try XCTUnwrap(fixture.host.cloudPresentationContext)

        await fixture.host.receiveCloudCallback(try pending(fixture, code: "replacement"))
        let replacement = try XCTUnwrap(fixture.host.cloudPresentationContext)
        await fixture.host.signOut(expectedCloud: original)

        XCTAssertEqual(fixture.host.cloudPresentationContext, replacement)
        let authorization = try await fixture.runtime.sessions.authorization(for: replacement.fence)
        XCTAssertEqual(authorization.token, "access-replacement")

        await fixture.host.signOut(expectedCloud: replacement)
        XCTAssertNil(fixture.host.cloud)
        XCTAssertNil(try fixture.runtime.registry.selectedID())
        XCTAssertNil(fixture.host.unconfirmedSignOutID)
    }

    func testSelfHostedSignOutReportsUnconfirmedRevocationWithoutALoginError() async throws {
        let fixture = fixture()
        let instance = TesseraeInstance(id: "test-server", name: "Test Server", baseURL: issuer,
            serverVersion: "1.0", timezone: "UTC", webURL: "/")
        let fence = try await fixture.runtime.installLocal(.init(instance: instance, token: "local-token",
            tokenID: "local", scopes: [], createdAt: Date()))
        await fixture.host.restore()
        XCTAssertEqual(fixture.local.activeFenceForSignOut, fence)

        // The fixture transport returns 503 for the server's revocation request.
        await fixture.host.signOut()

        XCTAssertNil(fixture.local.activeInstance)
        XCTAssertNil(try fixture.runtime.registry.selectedID())
        XCTAssertNil(fixture.host.loginError)
        XCTAssertNotNil(fixture.host.unconfirmedSignOutID)
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

    func testAdvertisedAppleWebTakesPrecedenceAndPreservesCloudAuthorization() async throws {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.configureApple(webAdvertised: true)
        XCTAssertFalse(fixture.host.appleSignInAvailable)
        await fixture.host.checkAppleSignInAvailability()
        XCTAssertTrue(fixture.host.appleSignInAvailable)
        await fixture.host.beginAppleSignIn()
        await fixture.host.beginAppleSignIn()

        XCTAssertEqual(fixture.host.loginPhase, .appleWeb)
        XCTAssertEqual(fixture.browser.opened.count, 1)
        XCTAssertNil(fixture.apple.nonce)
        let requests = await fixture.http.appleRequests
        XCTAssertEqual(requests.map(\.path), ["/auth/providers"])

        let pending = try XCTUnwrap(fixture.vault.pending())
        let url = try XCTUnwrap(fixture.browser.opened.first)
        XCTAssertEqual(url.scheme, appleIssuer.scheme)
        XCTAssertEqual(url.host, appleIssuer.host)
        XCTAssertEqual(url.port, appleIssuer.port)
        XCTAssertEqual(url.path, "/auth/apple/web/start")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.map(\.name), ["next"])
        let next = try XCTUnwrap(query.first?.value)
        let original = try XCTUnwrap(URLComponents(url: pending.authorizationURL, resolvingAgainstBaseURL: false))
        XCTAssertEqual(next, "/oauth/authorize?\(try XCTUnwrap(original.percentEncodedQuery))")
        let authorization = try XCTUnwrap(URLComponents(string: next))
        let items = try XCTUnwrap(authorization.queryItems)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let challenge = Data(SHA256.hash(data: Data(pending.verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(fields, [
            "response_type": "code", "client_id": PendingCloudLogin.clientID, "redirect_uri": PendingCloudLogin.callback,
            "resource": appleIssuer.appending(path: "api/t").absoluteString, "scope": PendingCloudLogin.scopes,
            "state": pending.state, "code_challenge_method": "S256", "code_challenge": challenge
        ])

        let callback = try XCTUnwrap(URL(string: PendingCloudLogin.callback + "?state=\(pending.state)&code=apple-web"))
        fixture.browser.finish(callback)
        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.host.isSigningIn, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let expected = ConnectionIdentity.cloud(issuer: appleIssuer, userID: "u1", tenantID: "t1").id
        XCTAssertEqual(fixture.host.cloud?.fence.connectionID, expected)
        XCTAssertEqual(try fixture.runtime.registry.selectedID(), expected)
        XCTAssertNil(try fixture.vault.pending())
    }

    func testProductionAppleIsImmediatelyAvailableAndFollowsWebCapability() async throws {
        let issuer = AppConfiguration.defaultCloudIssuer
        let fixture = fixture(issuer: issuer)
        XCTAssertTrue(fixture.host.appleSignInAvailable)
        await fixture.host.beginAppleSignIn()
        XCTAssertEqual(fixture.host.loginPhase, .appleWeb)
        XCTAssertEqual(fixture.browser.opened.last?.path, "/auth/apple/web/start")
        fixture.browser.finish(nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        let coldStartRequests = await fixture.http.appleRequests
        XCTAssertTrue(coldStartRequests.isEmpty)

        await fixture.host.checkAppleSignInAvailability()
        XCTAssertFalse(fixture.host.appleSignInAvailable)
        await fixture.host.beginAppleSignIn()
        XCTAssertEqual(fixture.browser.opened.count, 1)
        XCTAssertNil(fixture.apple.nonce)

        await fixture.http.configureApple(advertised: false, webAdvertised: true)
        await fixture.host.checkAppleSignInAvailability()
        XCTAssertTrue(fixture.host.appleSignInAvailable)
        await fixture.host.beginAppleSignIn()
        XCTAssertEqual(fixture.host.loginPhase, .appleWeb)
        XCTAssertEqual(fixture.browser.opened.last?.host, issuer.host)
        fixture.browser.finish(nil, error: ASWebAuthenticationSessionError(.canceledLogin))
        XCTAssertEqual(fixture.host.loginPhase, .idle)
        XCTAssertNil(fixture.host.loginError)
        XCTAssertNil(try fixture.vault.pending())
    }

    func testImmediateAppleAvailabilityRequiresCanonicalProductionRootAndCloudRuntime() throws {
        let productionRoot = try XCTUnwrap(URL(string: "https://CLOUD.TESSERAE.INK:443/"))
        let production = fixture(issuer: productionRoot)
        XCTAssertTrue(production.host.appleSignInAvailable)

        let differentPort = try XCTUnwrap(URL(string: "https://cloud.tesserae.ink:8443"))
        XCTAssertFalse(fixture(issuer: differentPort).host.appleSignInAvailable)

        let withoutRuntime = ConnectionHost(local: production.local, runtime: nil, vault: production.vault,
            issuer: productionRoot, browser: production.browser, appleAuthorization: production.apple)
        XCTAssertFalse(withoutRuntime.appleSignInAvailable)
    }

    func testPendingAppleWebLoginRestoresAppleProgressAndCanBeCanceled() async throws {
        let fixture = fixture(issuer: appleIssuer)
        let pending = try PendingCloudLogin(issuer: appleIssuer, browserEntry: .apple)
        try fixture.vault.replace(pending)

        await fixture.host.restore()
        XCTAssertEqual(fixture.host.loginPhase, .appleWeb)
        XCTAssertTrue(fixture.host.canCancelLogin)
        XCTAssertTrue(fixture.browser.opened.isEmpty)
        XCTAssertTrue(fixture.host.cancelCloudSignIn())
        XCTAssertEqual(fixture.host.loginPhase, .idle)
        XCTAssertNil(try fixture.vault.pending())
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

    func testAppleEmailResendFailureKeepsCodeEntryAndCanRetry() async {
        let fixture = fixture(issuer: appleIssuer)
        await fixture.http.configureApple(verifyEmail: true)
        await fixture.host.checkAppleSignInAvailability()
        await fixture.host.beginAppleSignIn()

        let address = "member@example.invalid"
        await fixture.host.sendAppleEmailCode(address)
        XCTAssertEqual(fixture.host.loginPhase, .appleCode)

        await fixture.http.refuseNextAppleEmailRequest()
        await fixture.host.sendAppleEmailCode(address)
        XCTAssertEqual(fixture.host.loginPhase, .appleCode)
        XCTAssertNotNil(fixture.host.loginError)

        await fixture.host.sendAppleEmailCode(address)
        XCTAssertEqual(fixture.host.loginPhase, .appleCode)
        XCTAssertNil(fixture.host.loginError)
        let requests = await fixture.http.appleRequests.filter { $0.path == "/auth/apple/email" }
        XCTAssertEqual(requests.map { $0.body["email"] }, [address, address, address])
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
