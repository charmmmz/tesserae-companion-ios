import Foundation
import Testing
@testable import TesseraeKit

private actor SystemEntryHTTP: TesseraeHTTPTransporting {
    var status = 200
    var delay: Duration = .zero
    var postCount = 0
    var timeouts: [TimeInterval] = []
    let bootstrap: Data
    init() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        bootstrap = try Data(contentsOf: root.appending(path: "Contracts/Fixtures/cloud-bootstrap.json"))
    }
    func configure(status: Int = 200, delay: Duration = .zero) { self.status = status; self.delay = delay }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        if request.httpMethod != "POST" { return .init(data: bootstrap, statusCode: status) }
        postCount += 1; timeouts.append(request.timeoutInterval)
        try await Task.sleep(for: delay)
        return .init(data: Data("{\"sent\":[{\"device_id\":\"same-device\",\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"bytes\":12,\"errors\":[]}]}".utf8), statusCode: 200)
    }
}

private struct SystemEntryFixture {
    let root: URL
    let http: SystemEntryHTTP
    let runtime: ConnectionRuntime
    let fence: ConnectionFence
    let entry: CloudSystemEntry
    var identity: ConnectionIdentity { .cloud(issuer: URL(string: "http://localhost:9000")!, userID: "u1", tenantID: "t1") }
    var target: CloudSubmissionTarget { .init(id: "same-device", name: "Kitchen", geometry: try! .init(width: 800, height: 480)) }
    static func make() async throws -> SystemEntryFixture {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let http = try SystemEntryHTTP()
        let sessions = SharedSessionStore(directory: root, vault: TestSessionVault(directory: root.appending(path: "vault")), transport: http)
        let runtime = ConnectionRuntime(directory: root, identity: .init(appVersion: "test", installationID: "test"),
            credentials: InMemoryCredentialStore(), sessions: sessions, legacy: InMemoryCompanionStateStore(),
            isPrimary: false, transport: http)
        let fence = try await runtime.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600)))
        let entry = CloudSystemEntry(runtime: runtime, directory: root) { data, _, devices in
            let targets = try devices.map { device in
                CloudSubmissionTarget(id: device.id, name: device.name, geometry: try #require(device.panel.compositionGeometry))
            }
            return .init(targets: targets, outputs: targets.map {
                .init(data: data, format: .png, geometry: $0.geometry, targetIDs: [$0.id])
            })
        }
        return .init(root: root, http: http, runtime: runtime, fence: fence, entry: entry)
    }
    func request(reviewed: Bool = false) throws -> CloudEntryRequest {
        .photo(targets: try .init(connectionID: fence.connectionID, deviceIDs: [target.id],
                                 reviewedFence: reviewed ? fence : nil),
               data: Data([1, 2, 3]), contentType: "image/png", recipe: .init(fit: .fill))
    }
    func store() throws -> CloudSubmissionStore { try .init(directory: root, identity: identity) }
}

@Suite struct CloudSystemEntryTests {
    @Test func explicitDecisionWaitsForDurableResultAndNeverReplays() async throws {
        let f = try await SystemEntryFixture.make()
        let id = UUID()
        guard case .finished(let batch) = try await f.entry.submit(f.request(), decision: id) else {
            Issue.record("The system entry returned before durable completion"); return
        }
        #expect(!batch.isActive)
        #expect(batch.results.first?.outcome.isCleanGenerated == true)
        #expect(try f.store().pendingInputs(now: Date()).isEmpty)
        #expect(try f.store().result(id, now: Date()).results == batch.results)
        guard case .finished = try await f.entry.submit(f.request(), decision: id) else {
            Issue.record("A repeated decision did not return its original result"); return
        }
        #expect(await f.http.postCount == 1)
    }

    @Test func preparationFailureRetainsBeforeAuthThenExplicitContinueUsesSameDecision() async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(status: 503)
        let id = UUID()
        guard case .retained(let input, _) = try await f.entry.submit(f.request(), decision: id) else {
            Issue.record("Failed preparation did not preserve input"); return
        }
        #expect(await f.http.postCount == 0)
        #expect(try f.store().inputBytes(id, revision: input.revision, now: Date()) == Data([1, 2, 3]))
        await f.http.configure()
        guard case .retained(let unchanged, _) = try await f.entry.submit(f.request(), decision: id) else {
            Issue.record("Repeated submit must not acquire a previously retained decision"); return
        }
        #expect(unchanged.id == id)
        #expect(await f.http.postCount == 0)
        let context = try await f.entry.authorizedReadContext(for: f.fence)
        #expect(try await f.entry.pendingInputs(in: context).count == 1)
        guard case .finished(let batch) = try await f.entry.continueExplicitly(id,
            expectedRevision: input.revision, review: context) else { Issue.record("Continue failed"); return }
        #expect(batch.id == id)
        #expect(await f.http.postCount == 1)
    }

    @Test(arguments: [false, true])
    func beforeAcceptanceTimeoutOrCancellationReturnsDurableRetainedInput(cancel: Bool) async throws {
        let f = try await SystemEntryFixture.make()
        let entry = CloudSystemEntry(runtime: f.runtime, directory: f.root) { _, _, _ in
            try await Task.sleep(for: .seconds(1))
            throw CloudSubmissionError.invalidPreparation
        }
        let request = try f.request()
        let id = UUID()
        let started = ContinuousClock.now
        let operation = Task { try await entry.submit(request, decision: id, timeout: cancel ? 1 : 0.06) }
        if cancel {
            for _ in 0..<1000 {
                if try f.store().pendingInputs(now: Date()).contains(where: { $0.id == id }) { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            operation.cancel()
        }
        guard case .retained(let input, _) = try await operation.value else {
            Issue.record("A published input was not recovered through the bounded completion path"); return
        }
        #expect(input.id == id)
        #expect(started.duration(to: .now) < .seconds(0.7))
        #expect(await f.http.postCount == 0)
        #expect(try f.store().inputBytes(id, revision: input.revision, now: Date()) == Data([1, 2, 3]))
    }

    @Test func anotherLiveInputOwnerCannotBeTakenOrSubmitted() async throws {
        let f = try await SystemEntryFixture.make()
        let id = UUID()
        let owner = try f.store().retainInput(decision: id, request: f.request(), now: Date())
        defer { withExtendedLifetime(owner) {} }
        guard case .inProgress(let decision) = try await f.entry.submit(f.request(), decision: id) else {
            Issue.record("A live owner was stolen"); return
        }
        #expect(decision == id)
        #expect(await f.http.postCount == 0)
    }

    @Test func totalBudgetEndsClaimedWriteAsUnknownWithoutAnotherPost() async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(delay: .seconds(1))
        let began = ContinuousClock.now
        let id = UUID()
        guard case .notConfirmed = try await f.entry.submit(f.request(), decision: id, timeout: 0.15) else {
            Issue.record("Expired read budget must not expose a private result"); return
        }
        let batch = try f.store().result(id, now: Date())
        #expect(began.duration(to: .now) < .seconds(1))
        #expect(!batch.isActive)
        if case .unknown = batch.results.first?.outcome {} else { Issue.record("An in-flight timeout was reported as success") }
        #expect(await f.http.postCount == 1)
        #expect(await f.http.timeouts.allSatisfy { $0 <= 0.15 })
    }

    @Test func cancellationAfterClaimPersistsUnknownBeforeReturning() async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(delay: .seconds(2))
        let request = try f.request()
        let id = UUID()
        let operation = Task { try await f.entry.submit(request, decision: id) }
        for _ in 0..<1000 {
            if await f.http.postCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await f.http.postCount == 1)
        operation.cancel()
        guard case .notConfirmed = try await operation.value else { Issue.record("Cancelled read must not expose private results"); return }
        let batch = try f.store().result(id, now: Date())
        #expect(!batch.isActive)
        if case .unknown = batch.results.first?.outcome {} else { Issue.record("Claimed cancellation was not unknown") }
        #expect(await f.http.postCount == 1)
    }

    @Test(arguments: ["logout", "newEpoch", "readRevoked"])
    func lateCompletionCannotExposeBatchWithoutCurrentFenceAndReadPermission(change: String) async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(delay: .milliseconds(150))
        let id = UUID(), request = try f.request()
        let operation = Task { try await f.entry.submit(request, decision: id) }
        for _ in 0..<1000 {
            if await f.http.postCount == 1 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await f.http.postCount == 1)
        switch change {
        case "logout": try await f.runtime.closeConnection(f.fence)
        case "newEpoch":
            _ = try await f.runtime.installCloud(issuer: URL(string: "http://localhost:9000")!,
                response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600, grant: "new")))
        default: await f.http.configure(status: 403)
        }
        guard case .notConfirmed(let decision, _) = try await operation.value else {
            Issue.record("An old or read-restricted private batch escaped"); return
        }
        #expect(decision == id)
        let saved = try f.store().result(id, now: Date())
        #expect(saved.identity == f.identity)
        #expect(!saved.isActive)
        #expect(await f.http.postCount == 1)
    }

    @Test func reviewedOldEpochCannotRebindUntilExplicitSameIdentityContinue() async throws {
        let f = try await SystemEntryFixture.make()
        let request = try f.request(reviewed: true)
        let fresh = try await f.runtime.installCloud(issuer: URL(string: "http://localhost:9000")!,
            response: JSONDecoder().decode(CloudTokenResponse.self, from: tokenFixture(expires: 3600, grant: "new")))
        guard case .retained(let input, _) = try await f.entry.submit(request, decision: UUID()) else {
            Issue.record("Old review was silently rebound"); return
        }
        #expect(await f.http.postCount == 0)
        let current = try await f.entry.authorizedReadContext(for: fresh)
        guard case .finished(let batch) = try await f.entry.continueExplicitly(input.id,
            expectedRevision: input.revision, review: current) else { Issue.record("Authorized recovery failed"); return }
        #expect(batch.fence == fresh)
        #expect(await f.http.postCount == 1)
    }

    @Test func retainedInputDeletionAndExpiryCannotResurrectThroughA3OrStaleHandle() async throws {
        let f = try await SystemEntryFixture.make()
        let now = Date()
        let store = try f.store()
        let id = UUID()
        let admission = try store.retainInput(decision: id, request: f.request(reviewed: true), now: now)
        guard case .owned(let owned) = admission else { Issue.record("No owner"); return }
        defer { withExtendedLifetime(owned) {} }
        #expect(throws: CloudSubmissionError.decisionConflict) {
            try store.stage(decision: id, fence: f.fence, kind: .photo, targets: [f.target],
                outputs: [.init(data: Data([1]), format: .png, geometry: f.target.geometry, targetIDs: [f.target.id])], now: now)
        }
        let staged = try store.stage(decision: id, fence: f.fence, kind: .photo, targets: [f.target],
            outputs: [.init(data: Data([1]), format: .png, geometry: f.target.geometry, targetIDs: [f.target.id])], now: now, input: owned)
        try store.deleteInput(id, revision: owned.input.revision, now: now)
        #expect(throws: CloudSubmissionError.decisionClosed) { try store.accept(staged, now: now) }
        #expect(throws: CloudSubmissionError.mediaUnavailable) { try store.inputBytes(id, revision: 0, now: now) }
        #expect(throws: CloudSubmissionError.decisionClosed) {
            try store.retainInput(decision: id, request: f.request(), now: now.addingTimeInterval(10))
        }
        let expiring = try store.retainInput(decision: UUID(), request: f.request(), now: now)
        guard case .owned(let other) = expiring else { Issue.record("No input"); return }
        #expect(try store.pendingInputs(now: now.addingTimeInterval(7 * 86400 + 0.01)).isEmpty)
        #expect(throws: CloudSubmissionError.mediaUnavailable) {
            try store.inputBytes(other.input.id, revision: 0, now: now.addingTimeInterval(7 * 86400 + 0.01))
        }
    }

    @Test func sourceCleanupFailureAfterAcceptanceCannotExposeOrResubmitInput() async throws {
        let f = try await SystemEntryFixture.make()
        let now = Date(), id = UUID(), store = try f.store()
        guard case .owned(let owned) = try store.retainInput(decision: id, request: f.request(reviewed: true), now: now) else {
            Issue.record("Input not retained"); return
        }
        defer { withExtendedLifetime(owned) {} }
        let sourceFolder = store.directory.appending(path: "Inputs/\(id.uuidString)")
        let bytesURL = try #require(FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil).first)
        let prepared = try store.stage(decision: id, fence: f.fence, kind: .photo, targets: [f.target],
            outputs: [.init(data: Data([9]), format: .png, geometry: f.target.geometry, targetIDs: [f.target.id])], now: now, input: owned)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sourceFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceFolder.path) }
        #expect(throws: (any Error).self) { try store.accept(prepared, now: now) }
        #expect(FileManager.default.fileExists(atPath: bytesURL.path))
        #expect(throws: CloudSubmissionError.mediaUnavailable) { try store.inputBytes(id, revision: owned.input.revision, now: now) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sourceFolder.path)
        guard case .batch(let batch) = try store.retainInput(decision: id, request: f.request(reviewed: true), now: now) else {
            Issue.record("Accepted authority was lost after source cleanup failed"); return
        }
        #expect(batch.id == id)
        #expect(try store.pendingInputs(now: now).isEmpty)
    }

    @Test func twoContinueCallsShareOneAcceptanceAndOnePost() async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(status: 503)
        guard case .retained(let input, _) = try await f.entry.submit(f.request(), decision: UUID()) else {
            Issue.record("No pending input"); return
        }
        await f.http.configure(delay: .milliseconds(80))
        let context = try await f.entry.authorizedReadContext(for: f.fence)
        async let a = f.entry.continueExplicitly(input.id, expectedRevision: input.revision, review: context)
        async let b = f.entry.continueExplicitly(input.id, expectedRevision: input.revision, review: context)
        let results = try await [a, b]
        #expect(results.count == 2)
        #expect(await f.http.postCount == 1)
        #expect(try f.store().pendingInputs(now: Date()).isEmpty)
    }

    @Test func stopOnlyAffectsOwnServiceNotIndependentFixedDestinationRun() async throws {
        let f = try await SystemEntryFixture.make()
        await f.http.configure(delay: .milliseconds(150))
        let a = try CloudSubmissionService(runtime: f.runtime, directory: f.root, fence: f.fence)
        let b = try CloudSubmissionService(runtime: f.runtime, directory: f.root, fence: f.fence)
        let outputs = [CloudPhotoOutput(data: Data([1]), format: .png, geometry: f.target.geometry, targetIDs: [f.target.id])]
        let pa = try await a.preparePhoto(decision: UUID(), targets: [f.target], outputs: outputs)
        let pb = try await b.preparePhoto(decision: UUID(), targets: [f.target], outputs: outputs)
        _ = try await a.start(pa); _ = try await b.start(pb)
        for _ in 0..<1000 {
            if await f.http.postCount == 2 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await f.http.postCount == 2)
        try await a.stopExecution()
        for _ in 0..<1000 {
            if try await b.result(pb.decision).isActive == false { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(try await b.result(pb.decision).results.first?.outcome.isCleanGenerated == true)
    }
}

@Suite struct ConnectionResourceResolverTests {
    @Test func legacyRawResourceRemainsUniquelyLocalWhenCloudIsSelected() throws {
        let registry = ConnectionRegistry(directory: .temporaryDirectory.appending(path: UUID().uuidString))
        let local = TesseraeInstance(id: "legacy", name: "Local", baseURL: URL(string: "http://one.local:8765")!,
            serverVersion: "0.500", timezone: "UTC", webURL: "http://one.local:8765")
        try registry.save(.init(identity: local.connectionIdentity, name: local.name, localInstance: local, legacyInstanceID: local.id))
        let cloud = ConnectionIdentity.cloud(issuer: URL(string: "https://cloud.example")!, userID: "a", tenantID: "t")
        try registry.save(.init(identity: cloud, name: "Cloud")); try registry.select(cloud.id)
        let resolver = ConnectionResourceResolver(registry: registry)
        #expect(try resolver.resolve(["same-device"], kind: .display).connection.id == local.connectionIdentity.id)
        let encoded = ConnectionResourceID(connectionID: local.connectionIdentity.id, kind: "display", resourceID: "same-device").encoded
        #expect(try resolver.resolve([encoded], kind: .display).connection.id == local.connectionIdentity.id)
        #expect(throws: ConnectionError.invalidIdentity) {
            try resolver.resolve(["tesserae-resource-v2:not-base64"], kind: .display)
        }
    }

    @Test func fixedIdentityKindAndMalformedPrefixRejectWholeSelection() throws {
        let registry = ConnectionRegistry(directory: .temporaryDirectory.appending(path: UUID().uuidString))
        let a = ConnectionIdentity.cloud(issuer: URL(string: "https://cloud.example")!, userID: "a", tenantID: "t")
        let b = ConnectionIdentity.cloud(issuer: URL(string: "https://cloud.example")!, userID: "b", tenantID: "t")
        try registry.save(.init(identity: a, name: "A")); try registry.save(.init(identity: b, name: "B"))
        let resolver = ConnectionResourceResolver(registry: registry)
        let aid = ConnectionResourceID(connectionID: a.id, kind: "display", resourceID: "same").encoded
        let bid = ConnectionResourceID(connectionID: b.id, kind: "display", resourceID: "same").encoded
        #expect(try resolver.resolve([aid], kind: .display).connection.id == a.id)
        try registry.select(b.id)
        #expect(try resolver.resolve([aid], kind: .display).connection.id == a.id)
        for ids in [[aid, bid], [aid, "tesserae-resource-v2:bad"], ["same"],
                    [ConnectionResourceID(connectionID: a.id, kind: "dashboard", resourceID: "same").encoded],
                    [ConnectionResourceID(connectionID: a.id, kind: "display", resourceID: "").encoded]] {
            #expect(throws: ConnectionError.invalidIdentity) { try resolver.resolve(ids, kind: .display) }
        }
    }
}
