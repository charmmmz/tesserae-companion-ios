import Foundation

public struct PreparedCloudSubmission: Sendable {
    public var decision: UUID { staged.batch.id }
    public var fence: ConnectionFence { staged.batch.fence }
    let serviceID: UUID
    let staged: CloudStagedBatch
}

public actor CloudSubmissionService {
    public nonisolated let fence: ConnectionFence
    private let runtime: ConnectionRuntime
    private var store: CloudSubmissionStore
    private let serviceID = UUID()
    private let clock: @Sendable () -> Date
    private let writeTimeout: TimeInterval
    private var deadline: CloudEntryDeadline?
    private var stopped = false
    private var runs: [UUID: Task<Void, Never>] = [:]

    public init(runtime: ConnectionRuntime, directory: URL, fence: ConnectionFence,
                writeTimeout: TimeInterval = 60, clock: @escaping @Sendable () -> Date = Date.init) throws {
        guard let descriptor = try runtime.registry.connection(fence.connectionID),
              case .cloud = descriptor.identity, writeTimeout > 0, writeTimeout.isFinite else {
            throw ConnectionError.invalidIdentity
        }
        self.runtime = runtime
        self.fence = fence
        self.store = try .init(directory: directory, identity: descriptor.identity)
        self.clock = clock
        self.writeTimeout = writeTimeout
    }

    public func preparePhoto(decision: UUID, targets: [CloudSubmissionTarget],
                             outputs: [CloudPhotoOutput]) async throws -> PreparedCloudSubmission {
        try await preflight(targets: targets, scope: "app:send")
        return .init(serviceID: serviceID, staged: try store.stage(decision: decision, fence: fence,
            kind: .photo, targets: targets, outputs: outputs, now: clock()))
    }

    public func prepareCurrentPage(decision: UUID, deviceID: String) async throws -> PreparedCloudSubmission {
        let snapshot = try await bootstrap(scope: "app:refresh")
        guard let device = snapshot.devices.first(where: { $0.id == deviceID }),
              let geometry = device.panel.compositionGeometry else { throw CloudSubmissionError.changedGeometry }
        let target = CloudSubmissionTarget(id: device.id, name: device.name, geometry: geometry)
        return .init(serviceID: serviceID, staged: try store.stage(decision: decision, fence: fence,
            kind: .currentPage, targets: [target], outputs: [], now: clock()))
    }

    public func prepareResend(decision: UUID, sourceID: UUID, expectedRevision: Int,
                              selection: CloudResendSelection) async throws -> PreparedCloudSubmission {
        try await runtime.sessions.validate(fence)
        let staged = try store.stageResend(decision: decision, sourceID: sourceID,
            expectedRevision: expectedRevision, selection: selection, fence: fence, now: clock())
        try await preflight(targets: staged.batch.targets,
                            scope: staged.batch.kind == .photo ? "app:send" : "app:refresh")
        return .init(serviceID: serviceID, staged: staged)
    }

    public func start(_ prepared: PreparedCloudSubmission) async throws -> UUID {
        try Task.checkCancellation()
        guard !stopped, prepared.serviceID == serviceID, prepared.fence == fence else { throw ConnectionError.sessionChanged }
        let staged = prepared.staged
        let store = self.store
        let now = clock()
        let budget = try remaining(limit: 10)
        let deadline = self.deadline
        let accepted = try await runtime.sessions.commit(fence, timeout: budget) {
            if let deadline { _ = try deadline.remaining() }
            return try store.accept(staged, now: now)
        }
        guard accepted.owner != nil else { return accepted.batch.id }
        if stopped {
            try store.stop(accepted.batch.id, reason: .connectionChanged, now: clock())
            return accepted.batch.id
        }
        runs[accepted.batch.id] = Task { await self.execute(accepted) }
        return accepted.batch.id
    }

    public func history() async throws -> [CloudSubmissionBatch] {
        try await runtime.sessions.validate(fence)
        guard !stopped else { throw ConnectionError.sessionChanged }
        return try store.history(now: clock())
    }

    public func result(_ id: UUID) async throws -> CloudSubmissionBatch {
        try await runtime.sessions.validate(fence)
        guard !stopped else { throw ConnectionError.sessionChanged }
        return try store.result(id, now: clock())
    }

    public func preview(_ id: UUID, taskID: UUID) async throws -> Data? {
        let batch = try await result(id)
        guard let raster = batch.tasks.first(where: { $0.id == taskID })?.raster else { return nil }
        return try store.media(batch, raster: raster, now: clock())
    }

    public func deleteMedia(_ id: UUID) async throws {
        _ = try await result(id)
        try store.deleteMedia(id, now: clock())
        runs[id]?.cancel()
    }

    public func deleteResult(_ id: UUID) async throws {
        _ = try await result(id)
        try store.deleteResult(id, now: clock())
        runs[id]?.cancel()
    }

    public func stopExecution() throws {
        stopped = true
        for id in runs.keys {
            try store.stop(id, reason: .connectionChanged, now: clock())
        }
        for task in runs.values { task.cancel() }
    }


    func constrain(to deadline: CloudEntryDeadline, directory: URL, identity: ConnectionIdentity) throws {
        guard runs.isEmpty else { throw CloudSubmissionError.alreadyRunning }
        self.deadline = deadline
        store = try CloudSubmissionStore(directory: directory, identity: identity, deadline: deadline)
    }

    func prepareInput(_ input: CloudOwnedInput, preparation: CloudPhotoPreparation?) async throws -> PreparedCloudSubmission {
        let targets: [CloudSubmissionTarget]
        let outputs: [CloudPhotoOutput]
        if input.input.kind == .photo {
            guard let preparation else { throw CloudSubmissionError.invalidPreparation }
            targets = preparation.targets; outputs = preparation.outputs
            try await preflight(targets: targets, scope: "app:send")
        } else {
            let snapshot = try await bootstrap(scope: "app:refresh")
            guard let device = snapshot.devices.first(where: { $0.id == input.input.targets.deviceIDs.first }),
                  let geometry = device.panel.compositionGeometry else { throw CloudSubmissionError.changedGeometry }
            targets = [.init(id: device.id, name: device.name, geometry: geometry)]; outputs = []
        }
        _ = try remaining()
        return .init(serviceID: serviceID, staged: try store.stage(decision: input.input.id, fence: fence,
            kind: input.input.kind, targets: targets, outputs: outputs, now: clock(), input: input))
    }

    func run(_ prepared: PreparedCloudSubmission) async throws -> CloudSubmissionBatch {
        let id = try await start(prepared)
        let ownTask = runs[id]
        if let task = ownTask {
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        }
        let result = try store.completionAccess().result(id, now: clock())
        guard prepared.staged.owner == nil || !result.isActive else { throw CloudSubmissionError.storageUnavailable }
        return result
    }

    private func remaining(limit: TimeInterval = 60) throws -> TimeInterval {
        try deadline?.remaining(limit: limit) ?? limit
    }

    private func bootstrap(scope: String) async throws -> CloudBootstrap {
        guard !stopped else { throw ConnectionError.sessionChanged }
        let transport = try await runtime.cloudTransport(for: fence.connectionID, timeout: remaining(limit: 10))
        guard transport.fence == fence else { throw ConnectionError.sessionChanged }
        let snapshot = try await CloudReadClient(transport: transport, timeout: remaining(limit: 10)).bootstrap()
        guard snapshot.account.auth.scopes.contains(scope) else { throw ConnectionError.accessRestricted("insufficient_scope") }
        _ = try await runtime.sessions.authorization(for: fence, timeout: remaining(limit: 10))
        guard !stopped else { throw ConnectionError.sessionChanged }
        return snapshot
    }

    private func preflight(targets: [CloudSubmissionTarget], scope: String) async throws {
        let snapshot = try await bootstrap(scope: scope)
        guard !targets.isEmpty, Set(targets.map(\.id)).count == targets.count else { throw CloudSubmissionError.invalidPreparation }
        for target in targets {
            guard let device = snapshot.devices.first(where: { $0.id == target.id }),
                  device.panel.compositionGeometry == target.geometry else { throw CloudSubmissionError.changedGeometry }
        }
    }

    private func execute(_ accepted: CloudAcceptedBatch) async {
        defer { runs[accepted.batch.id] = nil; withExtendedLifetime(accepted.owner) {} }
        let batch = accepted.batch
        guard case .active(let runID) = batch.execution else { return }
        for task in batch.tasks {
            if Task.isCancelled || stopped {
                try? store.completionAccess().stop(batch.id, reason: .connectionChanged, now: clock())
                return
            }
            var claim: CloudSubmissionClaim?
            do {
                let transport = try await runtime.cloudTransport(for: fence.connectionID, timeout: remaining(limit: 10))
                guard transport.fence == fence else { throw ConnectionError.sessionChanged }
                let client = try CloudSubmissionClient(transport: transport, writeTimeout: remaining(limit: writeTimeout))
                let bytes = try task.raster.map { try store.media(batch, raster: $0, now: clock()) }
                let request = try client.request(batch: batch, task: task, data: bytes)
                _ = try await runtime.sessions.authorization(for: fence, timeout: remaining(limit: 10))
                let store = self.store
                let now = clock()
                let deadline = self.deadline
                claim = try await runtime.sessions.commit(fence, timeout: remaining(limit: 10)) {
                    if let deadline { _ = try deadline.remaining() }
                    return try store.claim(batchID: batch.id, taskID: task.id, runID: runID, fence: self.fence, now: now)
                }
                guard let claim else { return }
                let sender = try CloudSubmissionClient(transport: transport, writeTimeout: remaining(limit: writeTimeout))
                let results = try await sender.send(request, task: task)
                guard try store.resolve(batchID: batch.id, taskID: task.id, claim: claim, results: results, now: clock()) else { return }
                let hasUncertainOrRefused = results.contains {
                    switch $0.outcome { case .generated: false; default: true }
                }
                if hasUncertainOrRefused {
                    try store.stop(batch.id, reason: .stopped, now: clock())
                    return
                }
            } catch {
                let completionStore = store.completionAccess()
                if let claim {
                    let reason: CloudSubmissionProblem = error is CancellationError ? .cancelled : .network
                    let results = task.targetIDs.map { CloudTargetResult(id: $0,
                        outcome: .unknown(reason, message: "This send could not be confirmed. Check the display before sending again.")) }
                    _ = try? completionStore.resolve(batchID: batch.id, taskID: task.id, claim: claim, results: results, now: clock())
                }
                try? completionStore.stop(batch.id, reason: claim == nil ? .stopped : .network, now: clock())
                return
            }
        }
    }
}
