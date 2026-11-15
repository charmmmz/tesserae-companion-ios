import Foundation

public actor CloudSystemEntry {
    public typealias Rasterizer = @Sendable (Data, CloudPhotoRecipe, [CloudDevice]) async throws -> CloudPhotoPreparation
    private let runtime: ConnectionRuntime
    private let directory: URL
    private let rasterize: Rasterizer
    private let clock: @Sendable () -> Date

    public init(runtime: ConnectionRuntime, directory: URL,
                clock: @escaping @Sendable () -> Date = Date.init, rasterize: @escaping Rasterizer) {
        self.runtime = runtime; self.directory = directory; self.clock = clock; self.rasterize = rasterize
    }

    public func submit(_ request: CloudEntryRequest, decision: UUID,
                       timeout: TimeInterval = 30) async throws -> CloudEntryCompletion {
        let deadline = try CloudEntryDeadline(timeout: timeout)
        let targets = request.targets
        _ = try CloudEntryTargets(connectionID: targets.connectionID, deviceIDs: targets.deviceIDs,
            reviewedFence: targets.reviewedFence, reviewedGeometry: targets.reviewedGeometry)
        let store = try store(for: targets.connectionID, deadline: deadline)
        let admission = try store.retainInput(decision: decision, request: request, now: clock())
        return await perform(admission, store: store, deadline: deadline, explicitContext: nil)
    }

    public func authorizedReadContext(for fence: ConnectionFence) async throws -> CloudEntryReadContext {
        try await readContext(for: fence, deadline: CloudEntryDeadline(timeout: 10))
    }

    public func pendingInputs(in context: CloudEntryReadContext) async throws -> [CloudPendingInput] {
        let current = try await authorizedReadContext(for: context.fence)
        let pending = try store(for: current.fence.connectionID).pendingInputs(now: clock()).map(\.summary)
        try await runtime.sessions.validate(current.fence)
        return pending
    }

    public func previewInput(_ id: UUID, expectedRevision: Int,
                             in context: CloudEntryReadContext) async throws -> Data? {
        let current = try await authorizedReadContext(for: context.fence)
        let bytes = try store(for: current.fence.connectionID).inputBytes(id, revision: expectedRevision, now: clock())
        try await runtime.sessions.validate(current.fence)
        return bytes
    }

    public func discardInput(_ id: UUID, expectedRevision: Int,
                             in context: CloudEntryReadContext) async throws {
        let current = try await authorizedReadContext(for: context.fence)
        let store = try store(for: current.fence.connectionID)
        let now = clock()
        try await runtime.sessions.commit(current.fence) {
            try store.deleteInput(id, revision: expectedRevision, now: now)
        }
    }

    public func continueExplicitly(_ id: UUID, expectedRevision: Int,
                                  review: CloudEntryReadContext, timeout: TimeInterval = 30) async throws -> CloudEntryCompletion {
        let deadline = try CloudEntryDeadline(timeout: timeout)
        let current = try await readContext(for: review.fence, deadline: deadline)
        let store = try store(for: current.fence.connectionID, deadline: deadline)
        let admission = try store.acquireInput(id, revision: expectedRevision, now: clock())
        return await perform(admission, store: store, deadline: deadline, explicitContext: current)
    }

    public func replaceExplicitly(_ id: UUID, expectedRevision: Int, with request: CloudEntryRequest,
                                  decision: UUID, review: CloudEntryReadContext,
                                  timeout: TimeInterval = 30) async throws -> CloudEntryCompletion {
        guard case .photo = request, id != decision,
              request.targets.connectionID == review.fence.connectionID,
              request.targets.reviewedFence == review.fence,
              Set(request.targets.reviewedGeometry.keys) == Set(request.targets.deviceIDs) else {
            throw CloudSubmissionError.invalidPreparation
        }
        let deadline = try CloudEntryDeadline(timeout: timeout)
        let current = try await readContext(for: review.fence, deadline: deadline)
        let store = try store(for: current.fence.connectionID, deadline: deadline)
        let prepared = try store.prepareInputReplacement(id, revision: expectedRevision, decision: decision,
                                                        request: request, now: clock())
        let clock = self.clock
        let admission = try await runtime.sessions.commit(current.fence, timeout: deadline.remaining(limit: 10)) {
            _ = try deadline.remaining()
            return try store.publishInputReplacement(prepared, now: clock())
        }
        return await perform(admission, store: store, deadline: deadline, explicitContext: current)
    }

    private func perform(_ admission: CloudInputAdmission, store: CloudSubmissionStore,
                         deadline: CloudEntryDeadline, explicitContext: CloudEntryReadContext?) async -> CloudEntryCompletion {
        switch admission {
        case .pending(let input, let isLive):
            return isLive ? .inProgress(decision: input.id)
                : .retained(input.summary, message: String(localized: "This unsent item has been kept. Continue it explicitly in Tesserae Companion."))
        case .batch(let batch):
            return await existingResult(batch, store: store, deadline: deadline)
        case .owned(let owned):
            defer { withExtendedLifetime(owned.owner) {} }
            do {
                _ = try deadline.remaining()
                let fence: ConnectionFence
                if let explicitContext { fence = explicitContext.fence }
                else if let bound = owned.input.boundFence { fence = bound }
                else {
                    guard let current = try await runtime.sessions.fence(for: store.identity.id,
                        timeout: deadline.remaining(limit: 10)) else { throw ConnectionError.signedOut }
                    fence = current
                }
                let current = try await readContext(for: fence, deadline: deadline)
                let scope = owned.input.kind == .photo ? "app:send" : "app:refresh"
                guard current.snapshot.account.auth.scopes.contains(scope) else {
                    throw ConnectionError.accessRestricted("insufficient_scope")
                }
                let input = try store.bindInput(owned, fence: fence, explicitly: explicitContext != nil, now: clock())
                let devices = input.input.targets.deviceIDs.compactMap { id in current.snapshot.devices.first { $0.id == id } }
                guard devices.count == input.input.targets.deviceIDs.count,
                      input.input.targets.reviewedGeometry.allSatisfy({ id, geometry in
                          devices.first { $0.id == id }?.panel.compositionGeometry == geometry
                      }) else { throw CloudSubmissionError.changedGeometry }
                let preparation: CloudPhotoPreparation?
                if input.input.kind == .photo {
                    guard let bytes = try store.inputBytes(input.input.id, revision: input.input.revision, now: clock()),
                          let recipe = input.input.recipe else { throw CloudSubmissionError.mediaUnavailable }
                    let rasterize = self.rasterize
                    preparation = try await boundedOperation(timeout: deadline.remaining()) {
                        try await rasterize(bytes, recipe, devices)
                    }
                } else { preparation = nil }
                _ = try deadline.remaining()
                let service = try CloudSubmissionService(runtime: runtime, directory: directory, fence: fence, clock: clock)
                try await service.constrain(to: deadline, directory: directory, identity: store.identity)
                let prepared = try await service.prepareInput(input, preparation: preparation)
                let batch = try await service.run(prepared)
                return await existingResult(batch, store: store, deadline: deadline)
            } catch {
                return await completionAfterFailure(owned.input.id, store: store,
                    deadline: deadline, message: error.localizedDescription)
            }
        }
    }

    private func existingResult(_ original: CloudSubmissionBatch, store: CloudSubmissionStore,
                                deadline: CloudEntryDeadline) async -> CloudEntryCompletion {
        do {
            _ = try await readContext(for: original.fence, deadline: deadline)
            let batch = try store.completionAccess().result(original.id, now: clock())
            try await runtime.sessions.validate(original.fence, timeout: deadline.remaining(limit: 10))
            return batch.isActive ? .inProgress(decision: batch.id) : .finished(batch)
        } catch { return .notConfirmed(decision: original.id, message: error.localizedDescription) }
    }

    private func completionAfterFailure(_ id: UUID, store: CloudSubmissionStore, deadline: CloudEntryDeadline,
                                        message: String) async -> CloudEntryCompletion {
        do {
            let store = store.completionAccess()
            if let input = try store.pendingInputs(now: clock()).first(where: { $0.id == id }) {
                return .retained(input.summary, message: message)
            }
            let batch = try store.result(id, now: clock())
            return await existingResult(batch, store: store, deadline: deadline)
        } catch { return .notConfirmed(decision: id, message: message) }
    }

    private func store(for id: ConnectionID, deadline: CloudEntryDeadline? = nil) throws -> CloudSubmissionStore {
        guard let descriptor = try runtime.registry.connection(id), case .cloud = descriptor.identity else {
            throw ConnectionError.invalidIdentity
        }
        return try CloudSubmissionStore(directory: directory, identity: descriptor.identity, deadline: deadline)
    }

    private func readContext(for fence: ConnectionFence, deadline: CloudEntryDeadline) async throws -> CloudEntryReadContext {
        let transport = try await runtime.cloudTransport(for: fence.connectionID, timeout: deadline.remaining(limit: 10))
        guard transport.fence == fence else { throw ConnectionError.sessionChanged }
        let snapshot = try await CloudReadClient(transport: transport, timeout: deadline.remaining(limit: 10)).bootstrap()
        try await runtime.sessions.validate(fence, timeout: deadline.remaining(limit: 10))
        _ = try deadline.remaining()
        return .init(fence: fence, snapshot: snapshot)
    }
}
