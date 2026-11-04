import CryptoKit
import Foundation
import Security
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

private struct CloudAppTestVault: SessionVault {
    let directory: URL
    func read(_ id: ConnectionID) throws -> Data? {
        let file = directory.appending(path: id.rawValue)
        return FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
    }
    func write(_ data: Data, for id: ConnectionID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appending(path: id.rawValue), options: .atomic)
    }
}

private actor CloudAppHTTP: TesseraeHTTPTransporting {
    var bootstrap: [String: Any]
    var requests: [String] = []
    var status = 200
    var held: [String: CheckedContinuation<Void, Never>] = [:]
    var blocked: Set<String> = []
    var png = Data([137, 80, 78, 71, 13, 10, 26, 10, 1])
    init(_ bootstrap: [String: Any]) { self.bootstrap = bootstrap }
    func configure(status: Int) { self.status = status }
    func block(_ path: String) { blocked.insert(path) }
    func release(_ path: String) { blocked.remove(path); held.removeValue(forKey: path)?.resume() }
    func deletePages() { bootstrap["pages"] = [] }
    func deleteAllResources() { bootstrap["devices"] = []; bootstrap["pages"] = [] }
    func expandPages(_ count: Int) {
        let template = (bootstrap["pages"] as! [[String: Any]])[0]
        bootstrap["pages"] = (0..<count).map { index in
            var page = template; page["id"] = "cache-\(index)"; return page
        }
    }
    func reviseDevice() {
        var values = bootstrap["devices"] as! [[String: Any]]
        values[0]["name"] = "Latest device name"
        values[0]["last_seen_at"] = 1793770010
        bootstrap["devices"] = values
    }
    func revisePage() {
        var pages = bootstrap["pages"] as! [[String: Any]]
        pages[0]["updated_at"] = (pages[0]["updated_at"] as! Double) + 1
        bootstrap["pages"] = pages
        png.append(2)
    }
    func count(_ path: String) -> Int { requests.filter { $0 == path }.count }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        let path = request.url!.path
        requests.append(path)
        let capturedStatus = status
        if blocked.contains(path) { await withCheckedContinuation { held[path] = $0 } }
        if capturedStatus == -1 { throw URLError(.notConnectedToInternet) }
        if capturedStatus != 200 {
            return TesseraeHTTPResponse(data: Data(#"{"reason":"membership_removed"}"#.utf8), statusCode: capturedStatus, headers: ["Retry-After": "17"])
        }
        if path.hasSuffix(".png") { return TesseraeHTTPResponse(data: png, statusCode: 200) }
        let body: [String: Any]
        if path.hasSuffix("/devices") { body = ["devices": bootstrap["devices"]!] }
        else if path.hasSuffix("/pages") { body = ["pages": bootstrap["pages"]!] }
        else { body = bootstrap }
        return TesseraeHTTPResponse(data: try JSONSerialization.data(withJSONObject: body), statusCode: 200)
    }
}

private final class CloudTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}

@MainActor
final class CloudConnectionTests: XCTestCase {
    private let issuer = URL(string: "http://localhost:9000")!
    private func vault() -> CloudLoginVault {
        CloudLoginVault(directory: URL.temporaryDirectory.appending(path: UUID().uuidString), service: "test.cloud.oauth.\(UUID())")
    }
    private func callback(_ attempt: PendingCloudLogin, extra: String = "code=one") -> URL {
        URL(string: PendingCloudLogin.callback + "?state=\(attempt.state)&" + extra)!
    }
    func testPKCEAndAtomicPersistentSingleUseCallback() throws {
        let store = vault()
        let attempt = try PendingCloudLogin(issuer: issuer)
        try store.replace(attempt)
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query["redirect_uri"], PendingCloudLogin.callback)
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["resource"], issuer.appending(path: "api/t").absoluteString)
        XCTAssertEqual(query["scope"], PendingCloudLogin.scopes)
        XCTAssertNil(query["client_secret"])
        let otherProcessStore = CloudLoginVault(directory: store.directory, service: store.service)
        XCTAssertEqual(try store.claim(callback(attempt), issuer: issuer)?.0.id, attempt.id)
        XCTAssertNil(try otherProcessStore.claim(callback(attempt), issuer: issuer))
        XCTAssertTrue(try otherProcessStore.pending()!.consumed)
        try store.invalidate()
    }
    func testWrongStateDuplicateFieldsAndWrongCallbackLeaveAttemptUsable() throws {
        let store = vault(); let attempt = try PendingCloudLogin(issuer: issuer)
        try store.replace(attempt)
        for url in [URL(string: PendingCloudLogin.callback + "?state=wrong&code=x")!,
                    callback(attempt, extra: "code=x&code=y"),
                    URL(string: "com.charmmmz.tesseraecompanion://oauth/callback?state=\(attempt.state)&code=x")!] {
            XCTAssertThrowsError(try store.claim(url, issuer: issuer))
            XCTAssertFalse(try store.pending()!.consumed)
        }
        XCTAssertNotNil(try store.claim(callback(attempt), issuer: issuer))
        try store.invalidate()
    }
    func testDeniedIsPersistentlyConsumedAndExpiredCannotExchange() throws {
        let store = vault(); let attempt = try PendingCloudLogin(issuer: issuer)
        try store.replace(attempt)
        XCTAssertThrowsError(try store.claim(callback(attempt, extra: "error=access_denied"), issuer: issuer))
        XCTAssertTrue(try store.pending()!.consumed)
        XCTAssertNil(try store.claim(callback(attempt), issuer: issuer))
        let expired = try PendingCloudLogin(issuer: issuer, now: Date().addingTimeInterval(-901))
        try store.replace(expired)
        XCTAssertThrowsError(try store.claim(callback(expired), issuer: issuer))
        try store.invalidate()
    }

    private func fixture(clock: CloudTestClock = CloudTestClock()) async throws -> (CloudBrowseModel, CloudAppHTTP) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let body = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Contracts/Fixtures/cloud-bootstrap.json"))) as! [String: Any]
        let http = CloudAppHTTP(body)
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let sessions = SharedSessionStore(directory: directory, vault: CloudAppTestVault(directory: directory.appending(path: "vault")), transport: http)
        let runtime = ConnectionRuntime(directory: directory, identity: TesseraeClientIdentity(appVersion: "test", installationID: "test"),
            credentials: InMemoryCredentialStore(), sessions: sessions, legacy: InMemoryCompanionStateStore(), isPrimary: true, transport: http)
        let response = try JSONDecoder().decode(CloudTokenResponse.self, from: Data("""
        {"access_token":"synthetic","token_type":"Bearer","expires_in":3600,"refresh_token":"synthetic-refresh","refresh_expires_in":86400,"scope":"app:read app:send app:refresh","resource":"http://localhost:9000/api/t","grant_id":"g1","generation":0,"user":{"id":"u1","email":"u@example.invalid"},"tenant":{"id":"t1","name":"Test"},"role":"member"}
        """.utf8))
        let fence = try await runtime.installCloud(issuer: issuer, response: response)
        let client = try await CloudReadClient(transport: runtime.cloudTransport(for: fence.connectionID))
        return (CloudBrowseModel(client: client, now: clock.now), http)
    }
    func testBootstrapDeduplicatesAndNeverRequestsRender() async throws {
        let (model, http) = try await fixture()
        await http.block("/api/t/bootstrap")
        let first = Task { await model.refresh() }; let second = Task { await model.refresh() }
        await wait(http, path: "/api/t/bootstrap")
        await http.release("/api/t/bootstrap")
        await first.value; await second.value
        XCTAssertEqual(model.devices.count, 2)
        let requests = await http.requests
        XCTAssertEqual(requests, ["/api/t/bootstrap"])
    }
    func testCachedPageIsRevalidatedAndExpiresAfterSixtySeconds() async throws {
        let clock = CloudTestClock(); let (model, http) = try await fixture(clock: clock)
        await model.refresh()
        let id = try XCTUnwrap(model.pages.first?.id)
        let path = "/api/t/pages/\(id)/thumb.png"
        await model.openDetail(id: id, isDevice: false)
        await model.openDetail(id: id, isDevice: false)
        var count = await http.count(path); XCTAssertEqual(count, 1)
        clock.advance(61)
        await model.openDetail(id: id, isDevice: false)
        count = await http.count(path); XCTAssertEqual(count, 2)
        await http.revisePage()
        await model.openDetail(id: id, isDevice: false)
        count = await http.count(path); XCTAssertEqual(count, 3)
        await http.deletePages()
        await model.openDetail(id: id, isDevice: false)
        XCTAssertTrue(model.pages.isEmpty)
        XCTAssertFalse(model.verifiedDetails.contains(CloudBrowseModel.key(id, false)))
        count = await http.count(path); XCTAssertEqual(count, 3)
    }
    func testPermissionFailureFencesConcurrentLatePreviewAndEndsLoading() async throws {
        let (model, http) = try await fixture()
        await model.refresh()
        let id = try XCTUnwrap(model.devices.first?.id)
        let path = "/api/t/devices/\(id)/frame.png"
        await http.block(path)
        let preview = Task { await model.openDetail(id: id, isDevice: true) }
        await wait(http, path: path)
        await http.configure(status: 403)
        await model.refresh()
        XCTAssertNil(model.snapshot); XCTAssertTrue(model.isRestricted); XCTAssertFalse(model.isLoading)
        await http.release(path); await preview.value
        XCTAssertTrue(model.previews.isEmpty)
        XCTAssertTrue(model.verifiedDetails.isEmpty)
    }
    func testRetryAfterKeepsCurrentDataAndDoesNotDispatchEarlyRetry() async throws {
        let (model, http) = try await fixture()
        await model.refresh(); await http.configure(status: 429)
        await model.refresh()
        XCTAssertNotNil(model.snapshot); XCTAssertNotNil(model.retryAfter)
        await model.refresh()
        let count = await http.count("/api/t/bootstrap")
        XCTAssertEqual(count, 2)
        XCTAssertFalse(model.needsSignIn)
    }
    func testDetailUsesLatestListMetadataAndEmptySuccessIsDistinctFromFailure() async throws {
        let (model, http) = try await fixture()
        await model.refresh()
        let id = try XCTUnwrap(model.devices.first?.id)
        await http.reviseDevice()
        await model.openDetail(id: id, isDevice: true)
        XCTAssertEqual(model.devices.first?.name, "Latest device name")
        XCTAssertEqual(model.devices.first?.lastSeenAt, Date(timeIntervalSince1970: 1793770010))
        await http.deleteAllResources()
        await model.refresh()
        XCTAssertNotNil(model.snapshot)
        XCTAssertTrue(model.devices.isEmpty); XCTAssertTrue(model.pages.isEmpty)
        XCTAssertNil(model.problem)
    }
    func testLimitServiceAndOfflineKeepCurrentDataWhilePermissionFailureClearsIt() async throws {
        for status in [402, 503, -1, 403] {
            let (model, http) = try await fixture()
            await model.refresh(); await http.configure(status: status)
            await model.refresh()
            XCTAssertNotNil(model.problem)
            XCTAssertFalse(model.isLoading)
            if status == 403 {
                XCTAssertNil(model.snapshot); XCTAssertTrue(model.isRestricted)
            } else {
                XCTAssertNotNil(model.snapshot); XCTAssertFalse(model.isRestricted)
                XCTAssertFalse(model.needsSignIn)
            }
            await http.configure(status: 200)
            await model.refresh()
            XCTAssertNotNil(model.snapshot, "A read error must not delete this grant")
        }
    }
    func testInactivePageCacheIsBoundedAndExpiredEntriesAreRemoved() async throws {
        let clock = CloudTestClock(); let (model, http) = try await fixture(clock: clock)
        await http.expandPages(20)
        await model.refresh()
        for page in model.pages {
            await model.openDetail(id: page.id, isDevice: false)
            model.closeDetail(id: page.id, isDevice: false)
            clock.advance(0.01)
        }
        XCTAssertLessThanOrEqual(model.previews.count, 12)
        clock.advance(61)
        await model.openDetail(id: "cache-19", isDevice: false)
        XCTAssertEqual(model.previews.count, 1)
        XCTAssertTrue(model.verifiedDetails.contains(CloudBrowseModel.key("cache-19", false)))
        model.closeDetail(id: "cache-19", isDevice: false)
        XCTAssertEqual(model.previews.count, 1)
    }
    private func wait(_ http: CloudAppHTTP, path: String) async {
        for _ in 0..<200 {
            if await http.count(path) > 0 { return }
            await Task.yield()
        }
        XCTFail("Expected request was not dispatched: \(path)")
    }
}
