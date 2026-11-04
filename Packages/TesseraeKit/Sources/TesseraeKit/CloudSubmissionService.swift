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
    private let store: CloudSubmissionStore
    private let serviceID = UUID()
    private let clock: @Sendable () -> Date
    private let writeTimeout: TimeInterval
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
        let accepted = try await runtime.sessions.commit(fence) { try store.accept(staged, now: now) }
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
        for batch in try store.history(now: clock()) where batch.fence == fence && batch.isActive {
            try store.stop(batch.id, reason: .connectionChanged, now: clock())
        }
        for task in runs.values { task.cancel() }
    }

    private func bootstrap(scope: String) async throws -> CloudBootstrap {
        guard !stopped else { throw ConnectionError.sessionChanged }
        let transport = try await runtime.cloudTransport(for: fence.connectionID)
        guard transport.fence == fence else { throw ConnectionError.sessionChanged }
        let snapshot = try await CloudReadClient(transport: transport).bootstrap()
        guard snapshot.account.auth.scopes.contains(scope) else { throw ConnectionError.accessRestricted("insufficient_scope") }
        _ = try await runtime.sessions.authorization(for: fence, timeout: 10)
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
                try? store.stop(batch.id, reason: .connectionChanged, now: clock())
                return
            }
            var claim: CloudSubmissionClaim?
            do {
                let transport = try await runtime.cloudTransport(for: fence.connectionID)
                guard transport.fence == fence else { throw ConnectionError.sessionChanged }
                let client = CloudSubmissionClient(transport: transport, writeTimeout: writeTimeout)
                let bytes = try task.raster.map { try store.media(batch, raster: $0, now: clock()) }
                let request = try client.request(batch: batch, task: task, data: bytes)
                _ = try await runtime.sessions.authorization(for: fence, timeout: 10)
                let store = self.store
                let now = clock()
                claim = try await runtime.sessions.commit(fence) {
                    try store.claim(batchID: batch.id, taskID: task.id, runID: runID, fence: self.fence, now: now)
                }
                guard let claim else { return }
                let results = try await client.send(request, task: task)
                guard try store.resolve(batchID: batch.id, taskID: task.id, claim: claim, results: results, now: clock()) else { return }
                let hasUncertainOrRefused = results.contains {
                    switch $0.outcome { case .generated: false; default: true }
                }
                if hasUncertainOrRefused {
                    try store.stop(batch.id, reason: .stopped, now: clock())
                    return
                }
            } catch {
                if let claim {
                    let reason: CloudSubmissionProblem = error is CancellationError ? .cancelled : .network
                    let results = task.targetIDs.map { CloudTargetResult(id: $0,
                        outcome: .unknown(reason, message: "This send could not be confirmed. Check the display before sending again.")) }
                    _ = try? store.resolve(batchID: batch.id, taskID: task.id, claim: claim, results: results, now: clock())
                }
                try? store.stop(batch.id, reason: claim == nil ? .stopped : .network, now: clock())
                return
            }
        }
    }
}
