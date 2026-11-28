import Foundation
import TesseraeKit
import Testing
@testable import Tesserae_Companion

private actor FinishQueue: ShareQueueStoring, LinkShareQueueStoring {
    var images: [SharedImageRequest] = []
    var links: [SharedLinkRequest] = []
    var holdImages = true
    var holdLinks = true
    var imageWaiting = false
    var linkWaiting = false
    var failOld = false
    var imageContinuation: CheckedContinuation<Void, Never>?
    var linkContinuation: CheckedContinuation<Void, Never>?
    func configure(images: [SharedImageRequest], links: [SharedLinkRequest], fail: Bool = false) {
        self.images = images; self.links = links; failOld = fail
    }
    func release() { imageContinuation?.resume(); linkContinuation?.resume(); imageContinuation = nil; linkContinuation = nil }
    func requests() async throws -> [SharedImageRequest] {
        let result = images, shouldFail = failOld
        if holdImages { holdImages = false; imageWaiting = true; await withCheckedContinuation { imageContinuation = $0 } }
        if shouldFail { throw ConnectionError.unavailable }
        return result
    }
    func requests() async throws -> [SharedLinkRequest] {
        let result = links, shouldFail = failOld
        if holdLinks { holdLinks = false; linkWaiting = true; await withCheckedContinuation { linkContinuation = $0 } }
        if shouldFail { throw ConnectionError.unavailable }
        return result
    }
    func enqueue(imageData: Data, request: SharedImageRequest) { images.append(request) }
    func enqueue(_ request: SharedLinkRequest) { links.append(request) }
    func imageData(for request: SharedImageRequest) -> Data { Data([1]) }
    func update(_ request: SharedImageRequest) { }
    func update(_ request: SharedLinkRequest) { }
    func remove(_ request: SharedImageRequest) { }
    func remove(_ request: SharedLinkRequest) { }
    func purge(expiredBefore date: Date) { }
}

private actor FinishCredentials: CredentialStoring {
    var values: [String: String] = [:]
    var waiting = false
    var continuation: CheckedContinuation<Void, Never>?
    func token(for instanceID: String) async -> String? {
        if instanceID == "A" {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            return nil
        }
        return values[instanceID]
    }
    func save(token: String, for instanceID: String) { values[instanceID] = token }
    func removeToken(for instanceID: String) { values[instanceID] = nil }
    func release() { continuation?.resume(); continuation = nil }
}

private actor PairPreparationHTTP: TesseraeHTTPTransporting {
    var waiting: Set<String> = []
    var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    func release(_ host: String) { continuations.removeValue(forKey: host)?.resume() }
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        let host = request.url!.host!
        waiting.insert(host)
        await withCheckedContinuation { continuations[host] = $0 }
        return .init(data: Data(), statusCode: 503)
    }
}

@MainActor struct ConnectionFinishIsolationTests {
    private func instance(_ name: String) -> TesseraeInstance {
        .init(id: name, name: name, baseURL: URL(string: "http://\(name.lowercased()).local")!,
              serverVersion: "0.311.0", timezone: "UTC", webURL: "/")
    }
    private func model(queue: FinishQueue, credentials: any CredentialStoring = InMemoryCredentialStore(),
                       store: any CompanionStateStoring = InMemoryCompanionStateStore(), runtime: ConnectionRuntime? = nil) -> AppModel {
        AppModel(liveClient: MockTesseraeClient(latency: .zero), connectionRuntime: runtime,
            demoClient: MockTesseraeClient(latency: .zero), credentials: credentials, stateStore: store,
            sendPreferences: InMemoryCompanionSendPreferencesStore(), shareQueue: queue, linkShareQueue: queue,
            activityThumbnails: InMemoryActivityThumbnailStore(), discovery: StaticDiscoveryService(results: []))
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<1000 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(1)) }
        Issue.record("Did not reach held queue/credential boundary"); throw CancellationError()
    }
    @Test(arguments: [false, true])
    func oldQueueLoadCannotReplaceNewConnectionCardsOrError(fail: Bool) async throws {
        let queue = FinishQueue()
        let bound = self.model(queue: queue)
        let a = instance("A"), b = instance("B")
        let imageA = SharedImageRequest(id: "image-A", instanceID: a.id, fileName: "a.png", contentType: "image/png", fit: .fit, deviceIDs: ["same"])
        let imageB = SharedImageRequest(id: "image-B", instanceID: b.id, fileName: "b.png", contentType: "image/png", fit: .fit, deviceIDs: ["same"])
        let linkA = SharedLinkRequest(id: "link-A", instanceID: a.id, url: URL(string: "https://a.invalid")!, kind: .webpage, fit: .fit, deviceIDs: ["same"])
        let linkB = SharedLinkRequest(id: "link-B", instanceID: b.id, url: URL(string: "https://b.invalid")!, kind: .webpage, fit: .fit, deviceIDs: ["same"])
        await queue.configure(images: [imageA], links: [linkA], fail: fail)
        bound.activeInstance = a; bound.connectionMode = .live
        let oldImages = Task { await bound.reloadQueuedImages(showErrors: true) }
        let oldLinks = Task { await bound.reloadQueuedLinks(showErrors: true) }
        try await wait { let image = await queue.imageWaiting; let link = await queue.linkWaiting; return image && link }
        bound.suspendForConnectionSwitch(); bound.activeInstance = b; bound.connectionMode = .live
        bound.connectionNotice = "B notice"; bound.queuedImagePreviewData = [imageB.id: Data([8])]
        await queue.configure(images: [imageB], links: [linkB])
        await bound.reloadQueuedImages(showErrors: true); await bound.reloadQueuedLinks(showErrors: true)
        await queue.release(); await oldImages.value; await oldLinks.value
        #expect(bound.queuedImageRequests.map(\.id) == [imageB.id])
        #expect(bound.queuedLinkRequests.map(\.id) == [linkB.id])
        #expect(bound.queuedImagePreviewData[imageB.id] == Data([8]))
        #expect(bound.connectionNotice == "B notice")
    }
    @Test func oldPrepareCleanupCannotClearNewPrepareBusyState() async throws {
        let http = PairPreparationHTTP(), credentials = InMemoryCredentialStore(), queue = FinishQueue()
        let client = LiveTesseraeClient(credentials: credentials,
            identity: .init(appVersion: "test", installationID: "test"), transport: http)
        let model = AppModel(liveClient: client, demoClient: MockTesseraeClient(latency: .zero),
            credentials: credentials, stateStore: InMemoryCompanionStateStore(),
            sendPreferences: InMemoryCompanionSendPreferencesStore(), shareQueue: queue, linkShareQueue: queue,
            activityThumbnails: InMemoryActivityThumbnailStore(), discovery: StaticDiscoveryService(results: []))
        let old = Task { try await model.prepareLocalConnection(baseURL: instance("A").baseURL, code: "123456", clientName: "A") }
        try await wait { await http.waiting.contains("a.local") }
        model.suspendForConnectionSwitch()
        let newer = Task { try await model.prepareLocalConnection(baseURL: instance("C").baseURL, code: "123456", clientName: "C") }
        try await wait { await http.waiting.contains("c.local") }
        await http.release("a.local")
        await #expect(throws: (any Error).self) { try await old.value }
        #expect(model.activeOperationIDs.contains("pair"))
        await http.release("c.local")
        await #expect(throws: (any Error).self) { try await newer.value }
        #expect(!model.activeOperationIDs.contains("pair"))
    }

    @Test func staleMissingLegacyCredentialDoesNotClearNewPairing() async throws {
        let credentials = FinishCredentials(), queue = FinishQueue()
        let a = instance("A"), b = instance("B")
        let state = InMemoryCompanionStateStore(snapshot: .init(activeInstance: a, capabilities: nil, displays: [], dashboards: [], jobs: []))
        let model = model(queue: queue, credentials: credentials, store: state)
        let restore = Task { await model.restoreConnectionIfNeeded() }
        try await wait { await credentials.waiting }
        let client = MockTesseraeClient(latency: .zero)
        let prepared = AppModel.PreparedConnection(attemptID: UUID(), candidate: client, mode: .live,
            capabilities: try await client.probe(baseURL: b.baseURL),
            session: .init(instance: b, token: "B-token", tokenID: "B-token-id", scopes: [], createdAt: Date()))
        _ = try await model.commitConnection(prepared)
        await credentials.release(); await restore.value
        #expect(model.activeInstance?.id == b.id)
        #expect(model.connectionHealth == .connected)
        #expect(try await state.load()?.activeInstance.id == b.id)
    }
}
