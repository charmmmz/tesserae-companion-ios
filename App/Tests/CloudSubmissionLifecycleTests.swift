import Foundation
import AppIntents
import Synchronization
import TesseraeKit
import Testing
import UIKit
@testable import Tesserae_Companion

private final class SubmissionGatedVault: SessionVault, @unchecked Sendable {
    private let condition = NSCondition()
    private var values: [ConnectionID: Data] = [:]
    private var blockedID: ConnectionID?
    private var remainingReads = 0
    private var waiting = false
    func block(_ id: ConnectionID, read: Int = 1) {
        condition.lock(); defer { condition.unlock() }
        blockedID = id; remainingReads = read; waiting = false
    }
    var isWaiting: Bool { condition.lock(); defer { condition.unlock() }; return waiting }
    func release() { condition.lock(); blockedID = nil; condition.broadcast(); condition.unlock() }
    func read(_ id: ConnectionID) throws -> Data? {
        condition.lock(); defer { condition.unlock() }
        if blockedID == id {
            remainingReads -= 1
            if remainingReads == 0 {
                waiting = true
                while blockedID == id { condition.wait() }
            }
        }
        return values[id]
    }
    func write(_ data: Data, for id: ConnectionID) throws { condition.lock(); values[id] = data; condition.unlock() }
}

private actor SubmissionLifecycleHTTP: TesseraeHTTPTransporting {
    let template: [String: Any]
    var postStatus = 200
    var unknownPost = false
    var postReason = "invalid_token"
    var readStatus = 200
    var holdPost = false
    var postWaiting = false
    var postContinuation: CheckedContinuation<Void, Never>?
    var postCount = 0
    var accountCount = 0
    var bootstrapCount = 0
    var failRefreshAfterPost = false
    var blockedUser: String?
    var waitingUser: String?
    var continuation: CheckedContinuation<Void, Never>?
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        template = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: "Contracts/Fixtures/cloud-bootstrap.json"))) as! [String: Any]
    }
    func useUnknownPost() { unknownPost = true }
    func configurePost(status: Int, reason: String = "invalid_token") { postStatus = status; postReason = reason }
    func failNextRefreshAfterPost() { failRefreshAfterPost = true }
    func configureRead(status: Int) { readStatus = status }
    func blockPost() { holdPost = true }
    func releasePost() { holdPost = false; postContinuation?.resume(); postContinuation = nil }
    func blockBootstrap(user: String) { blockedUser = user }
    func release() { blockedUser = nil; continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        let user = request.value(forHTTPHeaderField: "Authorization")?.contains("user-b") == true ? "u2" : "u1"
        if request.httpMethod == "POST" {
            postCount += 1
            let status = postStatus, reason = postReason
            if holdPost { postWaiting = true; await withCheckedContinuation { postContinuation = $0 } }
            if status == 200 {
                if unknownPost { return .init(data: Data("{\"sent\":[{\"device_id\":\"same-device\",\"error\":\"late failure\"}]}".utf8), statusCode: 200) }
                if failRefreshAfterPost { readStatus = 503 }
                return .init(data: Data("{\"sent\":[{\"device_id\":\"same-device\",\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"bytes\":12,\"errors\":[]}]}".utf8), statusCode: 200)
            }
            return .init(data: try JSONSerialization.data(withJSONObject: ["error": reason, "reason": reason]), statusCode: status)
        }
        if request.url?.path.hasSuffix("/bootstrap") == true { bootstrapCount += 1 }
        if readStatus != 200 {
            return .init(data: Data("{\"reason\":\"tenant_unavailable\"}".utf8), statusCode: readStatus)
        }
        if request.url?.path.hasSuffix("/bootstrap") == true, blockedUser == user {
            waitingUser = user
            await withCheckedContinuation { continuation = $0 }
        }
        var body = template
        var account = body["me"] as! [String: Any]
        account["user"] = ["id": user, "email": "\(user)@example.invalid"]
        body["me"] = account
        if request.url?.path.hasSuffix("/me") == true {
            accountCount += 1
            return .init(data: try JSONSerialization.data(withJSONObject: account), statusCode: 200)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: body), statusCode: 200)
    }
}

@MainActor struct CloudSubmissionLifecycleTests {
    private let issuer = URL(string: "http://localhost:9000")!
    private struct Fixture {
        let root: URL
        let host: ConnectionHost
        let local: AppModel
        let runtime: ConnectionRuntime
        let vault: SubmissionGatedVault
        let http: SubmissionLifecycleHTTP
        let a: ConnectionFence
        let b: ConnectionFence
    }
    private func token(_ label: String, user: String) throws -> CloudTokenResponse {
        try JSONDecoder().decode(CloudTokenResponse.self, from: JSONSerialization.data(withJSONObject: [
            "access_token": "access-\(label)", "token_type": "Bearer", "expires_in": 3600,
            "refresh_token": "refresh-\(label)", "refresh_expires_in": 86400,
            "scope": "app:read app:send app:refresh", "resource": issuer.appending(path: "api/t").absoluteString,
            "grant_id": "grant-\(label)", "generation": 0, "user": ["id": user, "email": "\(user)@example.invalid"],
            "tenant": ["id": "t1", "name": "Test"], "role": "member"]))
    }
    private func fixture() async throws -> Fixture {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = try SubmissionLifecycleHTTP(), vault = SubmissionGatedVault()
        let credentials = InMemoryCredentialStore()
        let sessions = SharedSessionStore(directory: root, vault: vault, transport: http)
        let runtime = ConnectionRuntime(directory: root, identity: .init(appVersion: "test", installationID: "test"),
            credentials: credentials, sessions: sessions, legacy: InMemoryCompanionStateStore(), isPrimary: true, transport: http)
        let local = AppModel(liveClient: runtime.bootstrapClient(), connectionRuntime: runtime,
            demoClient: MockTesseraeClient(latency: .zero), credentials: credentials, stateStore: runtime.stateStore,
            sendPreferences: InMemoryCompanionSendPreferencesStore(), shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(), activityThumbnails: InMemoryActivityThumbnailStore(), discovery: StaticDiscoveryService(results: []))
        let a = try await runtime.installCloud(issuer: issuer, response: token("user-a", user: "u1"))
        let b = try await runtime.installCloud(issuer: issuer, response: token("user-b", user: "u2"))
        let host = ConnectionHost(local: local, runtime: runtime,
            vault: CloudLoginVault(directory: root, service: "A3-test-\(UUID())"), issuer: issuer, submissionDirectory: root)
        await host.select(a.connectionID)
        return .init(root: root, host: host, local: local, runtime: runtime, vault: vault, http: http, a: a, b: b)
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Fixture did not reach its controlled boundary")
        throw CancellationError()
    }
    private func still() throws -> PreparedUploadImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 60, height: 40)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
        }
        return try UploadImagePreparer.prepare(data: image.pngData()!, fallbackContentType: "image/png")
    }
    @Test func cloudToDemoClearsPersistentSelectionAndLocalSnapshot() async throws {
        let fixture = try await fixture()
        await fixture.host.connectDemo()
        #expect(fixture.host.cloud == nil)
        #expect(fixture.local.connectionMode == .demo)
        #expect(try fixture.runtime.registry.selectedID() == nil)
        #expect(try await fixture.runtime.stateStore.load() == nil)
    }
    @Test func oldAcceptedContinuationCannotPresentIntoNewAccount() async throws {
        let fixture = try await fixture()
        let oldContext = try #require(fixture.host.cloudPresentationContext)
        let presentation = CompanionPresentation()
        await fixture.host.select(fixture.b.connectionID)
        presentation.sheet = .settings
        let oldID = UUID()
        let shown = fixture.host.withCurrentCloudPresentation(oldContext) {
            presentation.cloudResultID = oldID; presentation.sheet = .cloudResults
        }
        #expect(!shown)
        #expect(presentation.sheet == .settings)
        #expect(presentation.cloudResultID == nil)
        let current = try #require(fixture.host.cloudPresentationContext)
        #expect(fixture.host.withCurrentCloudPresentation(current) { presentation.cloudResultID = UUID() })
    }

    @Test func queuedOldRestrictionCannotStopNewCloudContext() async throws {
        let fixture = try await fixture()
        let oldModel = try #require(fixture.host.cloud)
        fixture.vault.block(fixture.b.connectionID)
        let switcher = Task { await fixture.host.select(fixture.b.connectionID) }
        try await wait { fixture.vault.isWaiting }
        oldModel.reportReadAuthorizationError(CloudReadError.forbidden(reason: "membership_removed"))
        let cleanup = Task { await fixture.host.cloudReadAccessChanged() }
        await Task.yield(); await Task.yield()
        fixture.vault.release()
        await switcher.value; await cleanup.value
        #expect(fixture.host.cloud?.fence == fixture.b)
        #expect(fixture.host.canUseCloudSubmissions)
        #expect(fixture.host.cloud?.snapshot?.account.user.id == "u2")
    }
    @Test func verifiedReadRecoveryCreatesNewServiceWithoutResumingOldWork() async throws {
        let fixture = try await fixture()
        let oldContext = try #require(fixture.host.cloudPresentationContext)
        let model = try #require(fixture.host.cloud)
        await fixture.http.blockPost()
        let id = try await fixture.host.submitCloudPhoto(media: still(), selectedIDs: ["same-device"], fit: .fit,
            framings: [:], decision: UUID(), context: oldContext)
        try await wait { await fixture.http.postWaiting }
        await fixture.http.configureRead(status: 403)
        await model.refresh(); await fixture.host.cloudReadAccessChanged()
        #expect(!fixture.host.canUseCloudSubmissions)
        await fixture.http.configureRead(status: 200)
        await model.refresh(); await fixture.host.cloudReadAccessChanged()
        #expect(fixture.host.canUseCloudSubmissions)
        let restored = try #require(fixture.host.cloudPresentationContext)
        #expect(restored.fence == oldContext.fence)
        #expect(restored.revision != oldContext.revision)
        await fixture.http.releasePost()
        let old = try await fixture.host.cloudSubmissionResult(id, context: restored)
        #expect(!old.isActive)
        if case .unknown = old.results.first?.outcome {} else { Issue.record("Stopped work must remain unknown") }
        #expect(await fixture.http.postCount == 1)
    }

    @Test func oldPreflightCannotPublishAfterSwitchWithSameRawTargetID() async throws {
        let fixture = try await fixture()
        let context = try #require(fixture.host.cloudPresentationContext)
        await fixture.http.blockBootstrap(user: "u1")
        let send = Task { try await fixture.host.submitCloudPhoto(media: still(), selectedIDs: ["same-device"],
            fit: .fit, framings: [:], decision: UUID(), context: context) }
        try await wait { await fixture.http.waitingUser == "u1" }
        await fixture.host.select(fixture.b.connectionID)
        await fixture.http.release()
        await #expect(throws: ConnectionError.sessionChanged) { try await send.value }
        #expect(await fixture.http.postCount == 0)
        let newContext = try #require(fixture.host.cloudPresentationContext)
        #expect(try await fixture.host.cloudSubmissionHistory(context: newContext).isEmpty)
    }
    @Test func oldEpochAuthorizationResultDoesNotRevokeNewLogin() async throws {
        let fixture = try await fixture()
        await fixture.http.configurePost(status: 401)
        let service = try CloudSubmissionService(runtime: fixture.runtime, directory: fixture.root, fence: fixture.a)
        let target = CloudSubmissionTarget(id: "same-device", name: "Kitchen", geometry: try .init(width: 800, height: 480))
        let prepared = try await service.preparePhoto(decision: UUID(), targets: [target], outputs: [
            .init(data: Data([1]), format: .png, geometry: target.geometry, targetIDs: [target.id])])
        let id = try await service.start(prepared)
        try await wait { (try? await service.result(id).isActive) == false }
        let fresh = try await fixture.runtime.installCloud(issuer: issuer, response: token("new-a", user: "u1"))
        await fixture.host.select(fresh.connectionID)
        let context = try #require(fixture.host.cloudPresentationContext)
        let history = try await fixture.host.cloudSubmissionResult(id, context: context)
        #expect(history.fence == fixture.a)
        #expect(fixture.host.cloud?.fence == fresh)
        #expect(fixture.host.canUseCloudSubmissions)
        #expect(fixture.host.cloud?.needsSignIn == false)
    }
    @Test func oldRestoreValidationCannotOverwriteNewLocalFence() async throws {
        let fixture = try await fixture()
        func instance(_ id: String) -> TesseraeInstance {
            .init(id: id, name: id, baseURL: URL(string: "http://\(id).local")!, serverVersion: "0.311.0", timezone: "UTC", webURL: "/")
        }
        let a = instance("local-a"), b = instance("local-b")
        let oldFence = try await fixture.runtime.installLocal(.init(instance: a, token: "A-token", tokenID: "A", scopes: [], createdAt: Date()))
        _ = try await fixture.runtime.stateStore.load()
        try await fixture.runtime.stateStore.save(.init(activeInstance: a, capabilities: nil, displays: [], dashboards: [], jobs: [], connectionFence: oldFence))
        fixture.vault.block(oldFence.connectionID, read: 3)
        let restore = Task { await fixture.local.restoreConnectionIfNeeded() }
        try await wait { fixture.vault.isWaiting }
        let candidate = MockTesseraeClient(latency: .zero)
        let prepared = AppModel.PreparedConnection(attemptID: UUID(), candidate: candidate, mode: .live,
            capabilities: try await candidate.probe(baseURL: b.baseURL),
            session: .init(instance: b, token: "B-token", tokenID: "B", scopes: [], createdAt: Date()))
        _ = try await fixture.local.commitConnection(prepared)
        let currentFence = try #require(fixture.local.activeFenceForSignOut)
        fixture.vault.release(); await restore.value
        #expect(fixture.local.activeInstance?.id == b.id)
        #expect(fixture.local.activeFenceForSignOut == currentFence)
        #expect(currentFence.connectionID == b.connectionIdentity.id)
        try await fixture.runtime.closeConnection(currentFence)
        try await fixture.runtime.sessions.validate(oldFence)
        await #expect(throws: ConnectionError.signedOut) { try await fixture.runtime.sessions.validate(currentFence) }
    }

    @Test func currentWrite401RechecksReadOnceWithoutReplayingPost() async throws {
        let fixture = try await fixture()
        await fixture.http.configurePost(status: 401)
        let context = try #require(fixture.host.cloudPresentationContext)
        let id = try await fixture.host.submitCloudPhoto(media: still(), selectedIDs: ["same-device"], fit: .fit,
            framings: [:], decision: UUID(), context: context)
        try await wait {
            guard let batch = try? await fixture.host.cloudSubmissionResult(id, context: context) else { return false }
            return !batch.isActive
        }
        _ = try await fixture.host.cloudSubmissionResult(id, context: context)
        #expect(await fixture.http.accountCount == 1)
        #expect(await fixture.http.postCount == 1)
        #expect(fixture.host.canUseCloudSubmissions)
        #expect(fixture.host.cloud?.needsSignIn == false)
    }
    @Test func newGeneratedResultRefreshesBrowseOnceAndSurvivesReadFailure() async throws {
        let fixture = try await fixture()
        let context = try #require(fixture.host.cloudPresentationContext)
        let initialReads = await fixture.http.bootstrapCount
        await fixture.http.failNextRefreshAfterPost()
        let id = try await fixture.host.submitCloudPhoto(media: still(), selectedIDs: ["same-device"], fit: .fit,
            framings: [:], decision: UUID(), context: context)
        try await wait { (try? await fixture.host.cloudSubmissionResult(id, context: context).isActive) == false }
        try await wait { await fixture.http.bootstrapCount == initialReads + 2 }
        let result = try await fixture.host.cloudSubmissionResult(id, context: context)
        #expect(result.results.first?.outcome.isCleanGenerated == true)
        _ = try await fixture.host.cloudSubmissionResult(id, context: context)
        #expect(await fixture.http.bootstrapCount == initialReads + 2)
        #expect(await fixture.http.postCount == 1)
        #expect(fixture.host.cloud?.snapshot != nil)
        #expect(fixture.host.canUseCloudSubmissions)
    }

    @Test func sendScopeRefusalDoesNotClearReadPresentation() async throws {
        let fixture = try await fixture()
        await fixture.http.configurePost(status: 403, reason: "insufficient_scope")
        let context = try #require(fixture.host.cloudPresentationContext)
        let id = try await fixture.host.submitCloudPhoto(media: still(), selectedIDs: ["same-device"], fit: .fit,
            framings: [:], decision: UUID(), context: context)
        try await wait { (try? await fixture.host.cloudSubmissionResult(id, context: context).isActive) == false }
        #expect(fixture.host.cloud?.snapshot != nil)
        #expect(fixture.host.cloud?.isRestricted == false)
        #expect(fixture.host.canUseCloudSubmissions)
        #expect(await fixture.http.accountCount == 0)
    }
}

extension CloudSubmissionLifecycleTests {
    @Test func fixedCloudIntentUsesOriginalIdentityWhenSelectionIsAnotherAccount() async throws {
        let fixture = try await fixture()
        await fixture.host.select(fixture.b.connectionID)
        let environment = TesseraeIntentRuntime(runtime: fixture.runtime, directory: fixture.root, suiteName: nil)
        let entities = try await environment.displays(identifiers: [ConnectionResourceID(connectionID: fixture.a.connectionID,
            kind: "display", resourceID: "same-device").encoded])
        #expect(entities.count == 1)
        #expect(entities.first?.connectionName?.contains("u1@") == true)
        let intent = SendImageToTesseraeIntent()
        intent.displays = entities
        intent.image = IntentFile(data: try still().data, filename: "marker.png", type: .png)
        intent.layout = .fit; intent.overrideQuietHours = false
        _ = try await intent.perform(using: environment)
        #expect(await fixture.http.postCount == 1)
        let historyA = try await CloudSubmissionService(runtime: fixture.runtime, directory: fixture.root, fence: fixture.a).history()
        let historyB = try await CloudSubmissionService(runtime: fixture.runtime, directory: fixture.root, fence: fixture.b).history()
        #expect(historyA.count == 1); #expect(historyB.isEmpty)
        #expect(try fixture.runtime.registry.selectedID() == fixture.b.connectionID)
    }
    @Test func cloudIntentRejectsQuietHoursAndMixedOrWrongKindBeforeAdmission() async throws {
        let fixture = try await fixture()
        let environment = TesseraeIntentRuntime(runtime: fixture.runtime, directory: fixture.root, suiteName: nil)
        func entity(_ fence: ConnectionFence, kind: String = "display") -> TesseraeDisplayEntity {
            .init(id: ConnectionResourceID(connectionID: fence.connectionID, kind: kind, resourceID: "same-device").encoded, name: "Fixed")
        }
        let intent = SendImageToTesseraeIntent()
        intent.image = IntentFile(data: try still().data, filename: "marker.png", type: .png)
        intent.layout = .fill; intent.overrideQuietHours = true; intent.displays = [entity(fixture.a)]
        await #expect(throws: TesseraeIntentError.self) { _ = try await intent.perform(using: environment) }
        intent.overrideQuietHours = false
        for targets in [[entity(fixture.a), entity(fixture.b)], [entity(fixture.a, kind: "dashboard")],
                        [.init(id: "tesserae-resource-v2:malformed", name: "Invalid")]] {
            intent.displays = targets
            await #expect(throws: ConnectionError.invalidIdentity) { _ = try await intent.perform(using: environment) }
        }
        #expect(await fixture.http.postCount == 0)
        let entry = environment.systemEntry()
        let read = try await entry.authorizedReadContext(for: fixture.a)
        #expect(try await entry.pendingInputs(in: read).isEmpty)
    }
    @Test func cloudIntentRefusalDoesNotReturnSuccessOrReplay() async throws {
        let fixture = try await fixture()
        await fixture.http.configurePost(status: 503, reason: "unavailable")
        let intent = RefreshCurrentCloudPageIntent()
        intent.display = .init(id: ConnectionResourceID(connectionID: fixture.a.connectionID,
            kind: "display", resourceID: "same-device").encoded, name: "Fixed")
        let environment = TesseraeIntentRuntime(runtime: fixture.runtime, directory: fixture.root, suiteName: nil)
        await #expect(throws: TesseraeIntentError.self) { _ = try await intent.perform(using: environment) }
        #expect(await fixture.http.postCount == 1)
    }
    @Test func cloudDashboardIntentIsExplicitlyUnsupportedWithoutCreatingPendingInput() async throws {
        let fixture = try await fixture()
        let intent = PushTesseraeDashboardIntent()
        intent.dashboard = .init(id: ConnectionResourceID(connectionID: fixture.a.connectionID,
            kind: "dashboard", resourceID: "page").encoded, name: "Page")
        intent.overrideQuietHours = false
        let environment = TesseraeIntentRuntime(runtime: fixture.runtime, directory: fixture.root, suiteName: nil)
        await #expect(throws: TesseraeIntentError.self) { _ = try await intent.perform(using: environment) }
        #expect(await fixture.http.postCount == 0)
    }
    @Test func pendingReadDoesNotSendAndSwitchCancelsOnlyOwnedRecovery() async throws {
        let fixture = try await fixture()
        let context = try #require(fixture.host.cloudPresentationContext)
        await fixture.http.configureRead(status: 503)
        let entry = CloudPhotoPreparer.systemEntry(runtime: fixture.runtime, directory: fixture.root)
        let outcome = try await entry.submit(.photo(targets: .init(connectionID: fixture.a.connectionID,
            deviceIDs: ["same-device"]), data: still().data, contentType: "image/png", recipe: .init(fit: .fit)), decision: UUID())
        guard case .retained = outcome else { Issue.record("Expected retained input"); return }
        await fixture.http.configureRead(status: 200)
        let pending = try await fixture.host.cloudPendingInputs(context: context)
        #expect(pending.count == 1); #expect(await fixture.http.postCount == 0)
        let review = try await fixture.host.cloudPendingReview(try #require(pending.first), context: context)
        #expect(!review.data.isEmpty); #expect(await fixture.http.postCount == 0)
        await fixture.http.blockPost()
        let task = Task { try await fixture.host.continueCloudPending(pending[0], review: review.read, context: context) }
        try await wait { await fixture.http.postWaiting }
        let switchTask = Task { await fixture.host.select(fixture.b.connectionID) }
        await Task.yield()
        await fixture.http.releasePost()
        await switchTask.value
        _ = try? await task.value
        #expect(fixture.host.cloudPresentationContext?.fence == fixture.b)
        #expect(await fixture.http.postCount == 1)
        #expect(!fixture.host.withCurrentCloudPresentation(context) {})
    }
}

extension CloudSubmissionLifecycleTests {
    @Test func unknownCloudIntentDoesNotReturnSuccess() async throws {
        let fixture = try await fixture()
        await fixture.http.useUnknownPost()
        let intent = RefreshCurrentCloudPageIntent()
        intent.display = .init(id: ConnectionResourceID(connectionID: fixture.a.connectionID,
            kind: "display", resourceID: "same-device").encoded, name: "Fixed")
        let environment = TesseraeIntentRuntime(runtime: fixture.runtime, directory: fixture.root, suiteName: nil)
        await #expect(throws: TesseraeIntentError.self) { _ = try await intent.perform(using: environment) }
        #expect(await fixture.http.postCount == 1)
        let history = try await CloudSubmissionService(runtime: fixture.runtime, directory: fixture.root, fence: fixture.a).history()
        guard case .unknown = history.first?.results.first?.outcome else { Issue.record("Expected durable unknown"); return }
    }
}

private actor LocalDashboardIntentHTTP: TesseraeHTTPTransporting {
    var hosts: [String] = []
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        hosts.append(request.url?.host ?? "")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return .init(data: try Data(contentsOf: root.appending(path: "Contracts/Fixtures/job-accepted.json")), statusCode: 202)
    }
}

extension CloudSubmissionLifecycleTests {
    @Test(arguments: [false, true])
    func sameRawIDKeepsBothLocalDisplayAndDashboardConnectionsAndPerformsOnB(useLegacyRaw: Bool) async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = LocalDashboardIntentHTTP(), vault = SubmissionGatedVault()
        let runtime = ConnectionRuntime(directory: root, identity: .init(appVersion: "test", installationID: "test"),
            credentials: InMemoryCredentialStore(), sessions: SharedSessionStore(directory: root, vault: vault, transport: http),
            legacy: InMemoryCompanionStateStore(), isPrimary: true, transport: http)
        var ids: [String] = []
        var displayIDs: [String] = []
        for host in ["local-a.invalid", "local-b.invalid"] {
            let instance = TesseraeInstance(id: "same-instance", name: host, baseURL: URL(string: "http://\(host)")!,
                serverVersion: "test", timezone: "UTC", webURL: "http://\(host)")
            let fence = try await runtime.installLocal(.init(instance: instance, token: "token", tokenID: "test", scopes: [], createdAt: Date()))
            let localDisplay = DisplaySummary(id: "desk", name: host, kind: "test_panel", iconName: "display",
                panel: .init(width: 160, height: 96, gamut: "mono", orientation: "landscape"), freshness: .fresh)
            try await runtime.stateStore.save(.init(activeInstance: instance, capabilities: nil, displays: [localDisplay],
                dashboards: [.init(id: "same-dashboard", name: host, kind: .canvas, deviceIDs: ["desk"])], jobs: [], connectionFence: fence))
            if useLegacyRaw && ids.isEmpty {
                try runtime.registry.save(.init(identity: instance.connectionIdentity, name: host,
                    localInstance: instance, legacyInstanceID: instance.id))
                ids.append("same-dashboard"); displayIDs.append("desk")
            } else {
                ids.append(ConnectionResourceID(connectionID: fence.connectionID, kind: "dashboard", resourceID: "same-dashboard").encoded)
                displayIDs.append(ConnectionResourceID(connectionID: fence.connectionID, kind: "display", resourceID: "desk").encoded)
            }
        }
        let environment = TesseraeIntentRuntime(runtime: runtime, directory: root, suiteName: nil)
        let entities = try await environment.dashboards(identifiers: ids)
        #expect(entities.map(\.id) == ids)
        #expect(Set(entities.map(\.id)).count == 2)
        let displayEntities = try await environment.displays(identifiers: displayIDs)
        #expect(displayEntities.map(\.id) == displayIDs)
        #expect(Set(displayEntities.map(\.id)).count == 2)
        if useLegacyRaw {
            let connections = try runtime.registry.savedConnections()
            let legacy = try #require(connections.first { $0.legacyInstanceID != nil })
            let dashboardAliases = ["same-dashboard", ConnectionResourceID(connectionID: legacy.id, kind: "dashboard", resourceID: "same-dashboard").encoded]
            let displayAliases = ["desk", ConnectionResourceID(connectionID: legacy.id, kind: "display", resourceID: "desk").encoded]
            #expect(try await environment.dashboards(identifiers: dashboardAliases).map(\.id) == dashboardAliases)
            #expect(try await environment.displays(identifiers: displayAliases).map(\.id) == displayAliases)
        }
        let intent = PushTesseraeDashboardIntent()
        intent.dashboard = try #require(entities.last); intent.overrideQuietHours = false
        _ = try await intent.perform(using: environment)
        #expect(await http.hosts == ["local-b.invalid"])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_RUN_CLOUD_SYSTEM_NATIVE"] == "1",
        "Requires the explicitly owned local C1 namespace; no network by default."))
    func prepareActualC1PendingPrivacyFixtures() async throws {
        let environment = try TesseraeIntentRuntime.live()
        let id = try #require(try environment.runtime.registry.selectedID())
        guard environment.directory.lastPathComponent.hasPrefix("a4-"),
              let connection = try environment.runtime.registry.connection(id),
              case .cloud(let issuer, _, _) = connection.identity,
              issuer.absoluteString == "http://127.0.0.1:8877" else { throw ConnectionError.invalidIdentity }
        let fence = try #require(try await environment.runtime.sessions.fence(for: id))
        var records: [[String: Any]] = []
        let isContinueFixture = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_SYSTEM_NATIVE_CASE"] == "continue"
        let cases = isContinueFixture ? [("continue", 86_400.0)] : [("detail", 70.0), ("review", 140.0)]
        for (name, lifetime) in cases {
            let created = Date().addingTimeInterval(-7 * 86_400 + lifetime)
            let entry = CloudSystemEntry(runtime: environment.runtime, directory: environment.directory, clock: { created }) { _, _, _ in
                throw CloudSystemMediaError.workingSet
            }
            let decision = UUID()
            let result = try await entry.submit(.photo(targets: .init(connectionID: id,
                deviceIDs: isContinueFixture ? ["a4_land"] : ["a4_land", "a4_removed"]), data: still().data, contentType: "image/png", recipe: .init(fit: .fill)), decision: decision)
            guard case .retained(let input, _) = result else { Issue.record("Expected unaccepted fixture input"); return }
            records.append(["case": name, "id": input.id.uuidString, "expires_at": input.expiresAt.timeIntervalSince1970])
        }
        try await environment.runtime.sessions.validate(fence)
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appending(path: "A4PendingPrivacyFixtures.json"), options: [.atomic])
    }
}

extension CloudSubmissionLifecycleTests {
    @Test func lateAcceptedPendingCannotDismissAnotherPresentationOrReopenedInput() async throws {
        let fixture = try await fixture()
        await fixture.http.configureRead(status: 503)
        let entry = CloudPhotoPreparer.systemEntry(runtime: fixture.runtime, directory: fixture.root)
        func pending() async throws -> CloudPendingInput {
            let result = try await entry.submit(.photo(targets: .init(connectionID: fixture.a.connectionID,
                deviceIDs: ["same-device"]), data: still().data, contentType: "image/png", recipe: .init(fit: .fit)), decision: UUID())
            guard case .retained(let input, _) = result else { throw CloudSubmissionError.invalidPreparation }
            return input
        }
        let a = try await pending(), b = try await pending()
        var presentation = CloudPendingPresentationState()
        presentation.show(a)
        let old = try #require(presentation.item?.id)
        presentation.item = nil
        presentation.show(b)
        let current = try #require(presentation.item?.id), batch = UUID()
        #expect(presentation.accept(batch, from: old) == nil)
        #expect(presentation.item?.input.id == b.id)
        #expect(presentation.accept(batch, from: current) == batch)
        #expect(presentation.item == nil)
        presentation.show(a)
        #expect(presentation.item?.id != old)
        #expect(presentation.accept(batch, from: old) == nil)
        #expect(presentation.item?.input.id == a.id)
    }
}
