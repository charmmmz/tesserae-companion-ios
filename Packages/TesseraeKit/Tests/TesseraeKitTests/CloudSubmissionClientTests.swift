import Foundation
import Testing
@testable import TesseraeKit

struct CloudSubmissionClientTests {
    private let digest = String(repeating: "a", count: 32)
    private func response(_ body: Any, status: Int = 200, headers: [String: String] = [:]) throws -> TesseraeHTTPResponse {
        .init(data: try JSONSerialization.data(withJSONObject: body), statusCode: status, headers: headers)
    }
    @Test func everyFrozenTargetGetsExactlyOneResult() throws {
        let reply = try response(["sent": [
            ["device_id": "a", "digest": digest, "bytes": 12, "errors": []],
            ["device_id": "b", "error": "event failed after commit"],
            ["device_id": "unrelated", "digest": digest, "bytes": 12, "errors": []]
        ]])
        let results = CloudSubmissionClient.parse(reply, targetIDs: ["a", "b", "c"], isPhoto: true)
        #expect(results.map(\.id) == ["a", "b", "c"])
        #expect(results[0].outcome.isCleanGenerated)
        if case .unknown = results[1].outcome {} else { Issue.record("Generic target error is ambiguous") }
        if case .unknown = results[2].outcome {} else { Issue.record("Missing row is unknown") }
    }
    @Test func duplicateRowCannotManufactureSuccess() throws {
        let row: [String: Any] = ["device_id": "a", "digest": digest, "bytes": 12, "errors": []]
        let results = CloudSubmissionClient.parse(try response(["sent": [row, row]]), targetIDs: ["a"], isPhoto: true)
        if case .unknown = results[0].outcome {} else { Issue.record("Duplicate rows are unknown") }
    }
    @Test func warningRetainsFrameButIsNotCleanSuccess() throws {
        let reply = try response(["sent": [["device_id": "a", "digest": digest, "bytes": 12,
                                            "errors": ["the image could not be decoded"]]]])
        let result = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: true)[0]
        #expect(!result.outcome.isCleanGenerated)
        if case .generated(let frame, let warnings) = result.outcome {
            #expect(frame.digest == digest); #expect(warnings.count == 1)
        } else { Issue.record("Committed warning frame must stay visible") }
    }
    @Test(arguments: [0, -1, 1.5, 9_223_372_036_854_775_808.0]) func invalidByteCountIsUnknown(bytes: Double) throws {
        let reply = try response(["sent": [["device_id": "a", "digest": digest, "bytes": bytes, "errors": []]]])
        if case .unknown = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: true)[0].outcome {} else {
            Issue.record("Invalid frame evidence")
        }
    }
    @Test func nullRefreshFrameIsNotGeneration() throws {
        let results = CloudSubmissionClient.parse(try response(["frame": NSNull()]), targetIDs: ["a"], isPhoto: false)
        if case .unknown(.noFrame, _) = results[0].outcome {} else { Issue.record("Null frame is not success") }
    }
    @Test func unboundCurrentPageIsNotAnImageError() throws {
        let reply = try response(["status": 400, "error": "device has no page assigned"], status: 400)
        if case .refused(.noFrame, _, _) = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: false)[0].outcome {} else {
            Issue.record("No current page is a distinct refusal")
        }
    }
    @Test func refreshFrameKeepsServerCurrentPage() throws {
        let reply = try response(["frame": ["digest": digest, "bytes": 12, "rendered_at": 1234, "page_id": "current-at-server"]])
        let result = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: false)[0]
        if case .generated(let frame, _) = result.outcome {
            #expect(frame.pageID == "current-at-server"); #expect(frame.renderedAt == Date(timeIntervalSince1970: 1234))
        } else { Issue.record("Expected generated frame") }
    }
    @Test(arguments: [400, 413, 415, 404, 402, 429, 503])
    func structuredPrecommitRefusalIsDistinct(status: Int) throws {
        let reply = try response(["status": status, "error": "synthetic refusal", "limit": "renders_per_day"],
            status: status, headers: ["Retry-After": status == 503 ? "20" : "17"])
        let result = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: true)[0]
        if case .refused(_, _, _) = result.outcome {} else { Issue.record("Expected proven refusal") }
    }
    @Test(arguments: ["1e300", "9223372036854775808", "inf", "-1"])
    func hugeRetryHeaderDoesNotBecomeANumericCountdown(value: String) throws {
        let reply = try response(["status": 429, "error": "rate limit"], status: 429, headers: ["Retry-After": value])
        let result = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: true)[0]
        if case .refused(.rateLimited, _, let retry) = result.outcome { #expect(retry == nil) }
        else { Issue.record("Rate refusal must remain explicit and non-replaying") }
    }
    @Test(arguments: [400, 402, 429, 503, 500])
    func statusAloneCannotProveRefusal(status: Int) {
        let reply = TesseraeHTTPResponse(data: Data("<html>gateway</html>".utf8), statusCode: status)
        if case .unknown = CloudSubmissionClient.parse(reply, targetIDs: ["a"], isPhoto: true)[0].outcome {} else {
            Issue.record("Untrusted failure body cannot prove phase")
        }
    }
}

private actor SubmissionFixtureHTTP: TesseraeHTTPTransporting {
    var posts: [URLRequest] = []
    var hold = false
    var continuation: CheckedContinuation<Void, Never>?
    let bootstrap: Data
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        bootstrap = try Data(contentsOf: root.appending(path: "Contracts/Fixtures/cloud-bootstrap.json"))
    }
    func configureHold() { hold = true }
    func unblock() { continuation?.resume(); continuation = nil; hold = false }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if request.httpMethod != "POST" { return .init(data: bootstrap, statusCode: 200) }
        posts.append(request)
        if hold { await withCheckedContinuation { continuation = $0 } }
        return .init(data: Data("{\"sent\":[{\"device_id\":\"same-device\",\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"bytes\":12,\"errors\":[]}]}".utf8), statusCode: 200)
    }
}

struct CloudSubmissionServiceTests {
    private func fixture() async throws -> (CloudSubmissionService, SubmissionFixtureHTTP, CloudSubmissionTarget) {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = try SubmissionFixtureHTTP()
        let sessions = SharedSessionStore(directory: root, vault: TestSessionVault(directory: root.appending(path: "vault")), transport: http)
        let runtime = ConnectionRuntime(directory: root,
            identity: .init(appVersion: "test", installationID: "test"), credentials: InMemoryCredentialStore(),
            sessions: sessions, legacy: InMemoryCompanionStateStore(), isPrimary: true, transport: http)
        let fence = try await runtime.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600)))
        return (try CloudSubmissionService(runtime: runtime, directory: root, fence: fence), http,
            .init(id: "same-device", name: "Kitchen", geometry: try .init(width: 800, height: 480)))
    }
    @Test func stableDecisionPublishesOnceAndSendsRealMultipart() async throws {
        let (service, http, target) = try await fixture()
        let decision = UUID()
        let output = CloudPhotoOutput(data: Data([1, 2, 3]), format: .png, geometry: target.geometry, targetIDs: [target.id])
        let prepared = try await service.preparePhoto(decision: decision, targets: [target], outputs: [output])
        #expect(try await service.start(prepared) == decision)
        #expect(try await service.start(prepared) == decision)
        for _ in 0..<1000 {
            if try await service.result(decision).isActive == false { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let result = try await service.result(decision)
        #expect(result.results.first?.outcome.isCleanGenerated == true)
        let posts = await http.posts
        #expect(posts.count == 1)
        let request = try #require(posts.first)
        #expect(request.url?.path == "/api/t/send/image")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body.contains("name=\"fit\"\r\n\r\nfit"))
        #expect(body.contains("name=\"rotate\"\r\n\r\n0"))
    }
    @Test func stopSealsActiveClaimAndNeverReopensIt() async throws {
        let (service, http, target) = try await fixture()
        await http.configureHold()
        let prepared = try await service.preparePhoto(decision: UUID(), targets: [target], outputs: [
            .init(data: Data([1]), format: .png, geometry: target.geometry, targetIDs: [target.id])])
        _ = try await service.start(prepared)
        for _ in 0..<1000 {
            if await http.posts.count == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await http.posts.count == 1)
        try await service.stopExecution()
        await http.unblock()
        await #expect(throws: ConnectionError.sessionChanged) { try await service.start(prepared) }
        #expect(await http.posts.count == 1)
    }
}
