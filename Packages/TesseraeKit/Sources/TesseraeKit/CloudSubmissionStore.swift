import CryptoKit
import Darwin
import Foundation

final class CloudRunOwner: @unchecked Sendable {
    private let descriptor: Int32

    private init(_ descriptor: Int32) { self.descriptor = descriptor }
    static func acquire(_ url: URL) throws -> CloudRunOwner? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CloudSubmissionError.storageUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            guard code == EWOULDBLOCK || code == EAGAIN else { throw CloudSubmissionError.storageUnavailable }
            return nil
        }
        return CloudRunOwner(fd)
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

struct CloudStagedBatch: Sendable {
    let batch: CloudSubmissionBatch
    let owner: CloudRunOwner?
    let expectedSourceRevision: Int?
    let confirmsDuplicates: Bool
}

struct CloudAcceptedBatch: Sendable {
    let batch: CloudSubmissionBatch
    let owner: CloudRunOwner?
}

private enum CloudLedgerRecord: Codable {
    case batch(CloudSubmissionBatch)
    case closed(UUID)
}

private struct CloudLedger: Codable {
    var records: [String: CloudLedgerRecord] = [:]
}

struct CloudSubmissionStore: Sendable {
    let identity: ConnectionIdentity
    let directory: URL
    private let metadataLock: SharedFileLock

    init(directory: URL, identity: ConnectionIdentity) throws {
        guard case let .cloud(issuer, user, tenant) = identity,
              try ConnectionIdentity.canonicalService(issuer) == issuer,
              !user.isEmpty, !tenant.isEmpty else { throw ConnectionError.invalidIdentity }
        self.identity = identity
        self.directory = directory.appending(path: "CloudSubmissions/\(identity.id.fileComponent)")
        metadataLock = SharedFileLock(url: self.directory.appending(path: "Locks/metadata.lock"))
    }

    func stage(decision: UUID, fence: ConnectionFence, kind: CloudSubmissionKind,
               targets: [CloudSubmissionTarget], outputs: [CloudPhotoOutput], now: Date) throws -> CloudStagedBatch {
        guard fence.connectionID == identity.id, !targets.isEmpty,
              Set(targets.map(\.id)).count == targets.count,
              targets.allSatisfy({ !$0.id.isEmpty && !$0.id.contains(",") }),
              kind == .photo || (targets.count == 1 && outputs.isEmpty) else {
            throw CloudSubmissionError.invalidPreparation
        }
        let ids = outputs.flatMap(\.targetIDs)
        if kind == .photo {
            guard !outputs.isEmpty, ids.count == Set(ids).count, Set(ids) == Set(targets.map(\.id)),
                  outputs.allSatisfy({ output in
                      !output.data.isEmpty && output.data.count <= 12_582_912 && !output.targetIDs.isEmpty
                          && output.targetIDs.allSatisfy { id in targets.first { $0.id == id }?.geometry == output.geometry }
                  }) else { throw CloudSubmissionError.invalidPreparation }
        }
        let fingerprint = try fingerprint(kind: kind, targets: targets, outputs: outputs, parent: nil)
        if let existing = try existing(decision, fingerprint: fingerprint, now: now) {
            return .init(batch: existing, owner: nil, expectedSourceRevision: nil, confirmsDuplicates: false)
        }
        guard let owner = try CloudRunOwner.acquire(ownerURL(decision)) else { throw CloudSubmissionError.alreadyRunning }
        let tasks: [CloudSubmissionTask]
        if kind == .photo {
            tasks = try outputs.map { output in
                let fileID = UUID()
                try writeMedia(output.data, batch: decision, file: fileID)
                return .init(id: UUID(), targetIDs: output.targetIDs,
                    raster: .init(fileID: fileID, format: output.format, geometry: output.geometry,
                                  digest: digest(output.data)), state: .prepared)
            }
        } else {
            tasks = [.init(id: UUID(), targetIDs: targets.map(\.id), raster: nil, state: .prepared)]
        }
        let batch = CloudSubmissionBatch(id: decision, identity: identity, fence: fence, kind: kind,
            parentID: nil, sourceRevision: nil, confirmedPossibleDuplicates: false, createdAt: now, resultsExpireAt: now.addingTimeInterval(30 * 86_400),
            mediaExpiresAt: kind == .photo ? now.addingTimeInterval(7 * 86_400) : nil,
            targets: targets, tasks: tasks, execution: .active(UUID()), revision: 0, fingerprint: fingerprint)
        return .init(batch: batch, owner: owner, expectedSourceRevision: nil, confirmsDuplicates: false)
    }

    func stageResend(decision: UUID, sourceID: UUID, expectedRevision: Int,
                     selection: CloudResendSelection, fence: ConnectionFence, now: Date) throws -> CloudStagedBatch {
        guard decision != sourceID, fence.connectionID == identity.id, !selection.targetIDs.isEmpty else {
            throw CloudSubmissionError.invalidPreparation
        }
        if let existing = try transaction(now: now, { ledger -> CloudSubmissionBatch? in
            guard let record = ledger.records[decision.uuidString] else { return nil }
            guard case .batch(let batch) = record else { throw CloudSubmissionError.decisionClosed }
            guard batch.parentID == sourceID, batch.sourceRevision == expectedRevision,
                  Set(batch.targets.map(\.id)) == selection.targetIDs,
                  batch.confirmedPossibleDuplicates == selection.confirmsPossibleDuplicates else {
                throw CloudSubmissionError.decisionConflict
            }
            return batch
        }) {
            return .init(batch: existing, owner: nil, expectedSourceRevision: expectedRevision,
                         confirmsDuplicates: selection.confirmsPossibleDuplicates)
        }
        let source = try result(sourceID, now: now)
        let targets = source.targets.filter { selection.targetIDs.contains($0.id) }
        guard targets.count == selection.targetIDs.count else { throw CloudSubmissionError.invalidPreparation }
        let originalOutputs = try source.tasks.compactMap { task -> CloudPhotoOutput? in
            let ids = task.targetIDs.filter { selection.targetIDs.contains($0) }
            guard !ids.isEmpty else { return nil }
            guard let raster = task.raster else { return nil }
            return .init(data: try media(source, raster: raster, now: now), format: raster.format,
                         geometry: raster.geometry, targetIDs: ids)
        }
        let fingerprint = try fingerprint(kind: source.kind, targets: targets, outputs: originalOutputs, parent: sourceID)
        if let existing = try existing(decision, fingerprint: fingerprint, now: now) {
            return .init(batch: existing, owner: nil, expectedSourceRevision: expectedRevision,
                         confirmsDuplicates: selection.confirmsPossibleDuplicates)
        }
        try validateResend(source, expectedRevision: expectedRevision, selection: selection, now: now)
        guard let owner = try CloudRunOwner.acquire(ownerURL(decision)) else { throw CloudSubmissionError.alreadyRunning }
        let tasks: [CloudSubmissionTask]
        if source.kind == .photo {
            tasks = try originalOutputs.map { output in
                let fileID = UUID()
                try writeMedia(output.data, batch: decision, file: fileID)
                return .init(id: UUID(), targetIDs: output.targetIDs,
                    raster: .init(fileID: fileID, format: output.format, geometry: output.geometry,
                                  digest: digest(output.data)), state: .prepared)
            }
        } else {
            tasks = targets.map { .init(id: UUID(), targetIDs: [$0.id], raster: nil, state: .prepared) }
        }
        let batch = CloudSubmissionBatch(id: decision, identity: identity, fence: fence, kind: source.kind,
            parentID: sourceID, sourceRevision: expectedRevision,
            confirmedPossibleDuplicates: selection.confirmsPossibleDuplicates, createdAt: now, resultsExpireAt: now.addingTimeInterval(30 * 86_400),
            mediaExpiresAt: source.mediaExpiresAt, targets: targets, tasks: tasks,
            execution: .active(UUID()), revision: 0, fingerprint: fingerprint)
        return .init(batch: batch, owner: owner, expectedSourceRevision: expectedRevision,
                     confirmsDuplicates: selection.confirmsPossibleDuplicates)
    }

    func accept(_ staged: CloudStagedBatch, now: Date) throws -> CloudAcceptedBatch {
        try transaction(now: now) { ledger in
            let key = staged.batch.id.uuidString
            if let record = ledger.records[key] {
                return .init(batch: try matching(record, fingerprint: staged.batch.fingerprint), owner: nil)
            }
            guard staged.owner != nil, staged.batch.identity == identity else { throw CloudSubmissionError.interrupted }
            for task in staged.batch.tasks {
                if let raster = task.raster { try requireMediaFile(staged.batch, raster: raster, now: now) }
            }
            if let sourceID = staged.batch.parentID {
                guard case .batch(var source) = ledger.records[sourceID.uuidString],
                      let revision = staged.expectedSourceRevision else { throw CloudSubmissionError.missingResult }
                let selection = CloudResendSelection(targetIDs: Set(staged.batch.targets.map(\.id)),
                    confirmsPossibleDuplicates: staged.confirmsDuplicates)
                try validateResend(source, expectedRevision: revision, selection: selection, now: now)
                guard source.resendReservation == nil || !isLiveResend(source.resendReservation!, in: ledger) else {
                    throw CloudSubmissionError.alreadyRunning
                }
                source.resendReservation = staged.batch.id
                source.revision += 1
                ledger.records[sourceID.uuidString] = .batch(source)
            }
            ledger.records[key] = .batch(staged.batch)
            return .init(batch: staged.batch, owner: staged.owner)
        }
    }

    func claim(batchID: UUID, taskID: UUID, runID: UUID, fence: ConnectionFence, now: Date) throws -> CloudSubmissionClaim? {
        try transaction(now: now) { ledger in
            guard case .batch(var batch) = ledger.records[batchID.uuidString], batch.fence == fence,
                  case .active(let activeRun) = batch.execution, activeRun == runID,
                  let index = batch.tasks.firstIndex(where: { $0.id == taskID }),
                  case .prepared = batch.tasks[index].state else { return nil }
            if let expiry = batch.mediaExpiresAt, expiry <= now { return nil }
            if let raster = batch.tasks[index].raster { try requireMediaFile(batch, raster: raster, now: now) }
            let claim = CloudSubmissionClaim(attemptID: UUID(), runID: runID, fence: fence, claimedAt: now)
            batch.tasks[index].state = .claimed(claim)
            batch.revision += 1
            ledger.records[batchID.uuidString] = .batch(batch)
            return claim
        }
    }

    @discardableResult
    func resolve(batchID: UUID, taskID: UUID, claim: CloudSubmissionClaim,
                 results: [CloudTargetResult], now: Date) throws -> Bool {
        try transaction(now: now) { ledger in
            guard case .batch(var batch) = ledger.records[batchID.uuidString],
                  case .active(let activeRun) = batch.execution, activeRun == claim.runID,
                  let index = batch.tasks.firstIndex(where: { $0.id == taskID }),
                  case .claimed(let currentClaim) = batch.tasks[index].state,
                  currentClaim.attemptID == claim.attemptID, currentClaim.runID == claim.runID,
                  currentClaim.fence == claim.fence,
                  Set(results.map(\.id)) == Set(batch.tasks[index].targetIDs),
                  results.count == batch.tasks[index].targetIDs.count else { return false }
            batch.tasks[index].state = .resolved(claim, results)
            batch.revision += 1
            if batch.results.count == batch.targets.count {
                batch.execution = .finished
                if batch.results.allSatisfy({ $0.outcome.isCleanGenerated }), let expiry = batch.mediaExpiresAt {
                    batch.mediaExpiresAt = min(expiry, now.addingTimeInterval(86_400))
                }
            }
            ledger.records[batchID.uuidString] = .batch(batch)
            return true
        }
    }

    func stop(_ id: UUID, reason: CloudSubmissionProblem, now: Date) throws {
        try transaction(now: now) { ledger in
            guard case .batch(var batch) = ledger.records[id.uuidString] else { return }
            seal(&batch, reason: reason)
            ledger.records[id.uuidString] = .batch(batch)
        }
    }

    func history(now: Date) throws -> [CloudSubmissionBatch] {
        try transaction(now: now) { ledger in
            var batches: [CloudSubmissionBatch] = []
            for (key, record) in ledger.records {
                guard case .batch(var batch) = record else { continue }
                if batch.isActive, let owner = try CloudRunOwner.acquire(ownerURL(batch.id)) {
                    withExtendedLifetime(owner) { seal(&batch, reason: .interrupted) }
                    ledger.records[key] = .batch(batch)
                }
                batches.append(batch)
            }
            return batches.sorted { $0.createdAt > $1.createdAt }
        }
    }

    func result(_ id: UUID, now: Date) throws -> CloudSubmissionBatch {
        guard let batch = try history(now: now).first(where: { $0.id == id }) else {
            throw CloudSubmissionError.missingResult
        }
        return batch
    }

    func deleteMedia(_ id: UUID, now: Date) throws {
        try transaction(now: now) { ledger in
            guard case .batch(var batch) = ledger.records[id.uuidString] else { throw CloudSubmissionError.missingResult }
            seal(&batch, reason: .deleted)
            batch.mediaExpiresAt = now
            batch.revision += 1
            ledger.records[id.uuidString] = .batch(batch)
        }
        try removeMedia(id)
    }

    func deleteResult(_ id: UUID, now: Date) throws {
        try transaction(now: now) { ledger in
            guard ledger.records[id.uuidString] != nil else { throw CloudSubmissionError.missingResult }
            ledger.records[id.uuidString] = .closed(id)
        }
        try removeMedia(id)
    }

    func media(_ batch: CloudSubmissionBatch, raster: CloudRasterReference, now: Date) throws -> Data {
        try transaction(now: now) { ledger in
            guard batch.identity == identity,
                  case .batch(let current) = ledger.records[batch.id.uuidString],
                  let expiry = current.mediaExpiresAt, expiry > now,
                  current.tasks.contains(where: { $0.raster?.fileID == raster.fileID && $0.raster?.digest == raster.digest }) else {
                throw CloudSubmissionError.mediaUnavailable
            }
            let data: Data
            do { data = try Data(contentsOf: mediaURL(current.id, raster.fileID)) }
            catch { throw CloudSubmissionError.mediaUnavailable }
            guard digest(data) == raster.digest else { throw CloudSubmissionError.mediaUnavailable }
            return data
        }
    }

    private func requireMediaFile(_ batch: CloudSubmissionBatch, raster: CloudRasterReference, now: Date) throws {
        guard let expiry = batch.mediaExpiresAt, expiry > now,
              FileManager.default.fileExists(atPath: mediaURL(batch.id, raster.fileID).path) else {
            throw CloudSubmissionError.mediaUnavailable
        }
    }

    private func validateResend(_ source: CloudSubmissionBatch, expectedRevision: Int,
                                selection: CloudResendSelection, now: Date) throws {
        guard !source.isActive, source.revision == expectedRevision else {
            throw source.isActive ? CloudSubmissionError.alreadyRunning : .resultChanged
        }
        guard let owner = try CloudRunOwner.acquire(ownerURL(source.id)) else { throw CloudSubmissionError.alreadyRunning }
        try withExtendedLifetime(owner) {
            let outcomes = Dictionary(uniqueKeysWithValues: source.results.map { ($0.id, $0.outcome) })
            guard selection.targetIDs.allSatisfy({ outcomes[$0] != nil }) else { throw CloudSubmissionError.invalidPreparation }
            if !selection.confirmsPossibleDuplicates,
               selection.targetIDs.contains(where: { outcomes[$0]?.needsDuplicateConfirmation == true }) {
                throw CloudSubmissionError.duplicateConfirmationRequired
            }
            if source.kind == .photo {
                guard let expiry = source.mediaExpiresAt, expiry > now else { throw CloudSubmissionError.mediaUnavailable }
            }
        }
    }

    private func isLiveResend(_ id: UUID, in ledger: CloudLedger) -> Bool {
        guard case .batch(let batch) = ledger.records[id.uuidString] else { return false }
        return batch.isActive
    }

    private func existing(_ id: UUID, fingerprint: String, now: Date) throws -> CloudSubmissionBatch? {
        try transaction(now: now) { ledger in
            guard let record = ledger.records[id.uuidString] else { return nil }
            return try matching(record, fingerprint: fingerprint)
        }
    }

    private func matching(_ record: CloudLedgerRecord, fingerprint: String) throws -> CloudSubmissionBatch {
        switch record {
        case .closed: throw CloudSubmissionError.decisionClosed
        case .batch(let batch):
            guard batch.fingerprint == fingerprint else { throw CloudSubmissionError.decisionConflict }
            return batch
        }
    }

    private func transaction<T>(now: Date, _ operation: (inout CloudLedger) throws -> T) throws -> T {
        try metadataLock.withLock {
            let url = directory.appending(path: "ledger.json")
            var ledger = try FileManager.default.fileExists(atPath: url.path)
                ? ConnectionCoding.decoder().decode(CloudLedger.self, from: Data(contentsOf: url)) : CloudLedger()
            for (key, record) in ledger.records {
                guard case .batch(var batch) = record else { continue }
                guard batch.identity == identity, key == batch.id.uuidString else { throw ConnectionError.invalidIdentity }
                if batch.resultsExpireAt <= now { ledger.records[key] = .closed(batch.id) }
                else if let expiry = batch.mediaExpiresAt, expiry <= now, batch.isActive {
                    seal(&batch, reason: .mediaExpired)
                    ledger.records[key] = .batch(batch)
                }
            }
            let value = try operation(&ledger)
            try writeProtected(ledger, to: url)
            try cleanupMedia(ledger, now: now)
            return value
        }
    }

    private func cleanupMedia(_ ledger: CloudLedger, now: Date) throws {
        let mediaRoot = directory.appending(path: "Media")
        guard FileManager.default.fileExists(atPath: mediaRoot.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: mediaRoot, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            switch ledger.records[id.uuidString] {
            case .batch(let batch):
                if let expiry = batch.mediaExpiresAt, expiry <= now { try removeMedia(id) }
            case .closed: try removeMedia(id)
            case nil:
                if let owner = try CloudRunOwner.acquire(ownerURL(id)) {
                    try withExtendedLifetime(owner) { try removeMedia(id) }
                }
            }
        }
    }

    private func seal(_ batch: inout CloudSubmissionBatch, reason: CloudSubmissionProblem) {
        guard batch.isActive else { return }
        for index in batch.tasks.indices {
            let task = batch.tasks[index]
            switch task.state {
            case .prepared: batch.tasks[index].state = .notAttempted(reason)
            case .claimed(let claim): batch.tasks[index].state = .resolved(claim, task.targetIDs.map {
                .init(id: $0, outcome: .unknown(reason, message: "The send could not be confirmed. Check the display before sending again."))
            })
            default: break
            }
        }
        batch.execution = .stopped(reason)
        batch.revision += 1
    }

    private func fingerprint(kind: CloudSubmissionKind, targets: [CloudSubmissionTarget],
                             outputs: [CloudPhotoOutput], parent: UUID?) throws -> String {
        struct Content: Encodable {
            let kind: CloudSubmissionKind
            let targets: [CloudSubmissionTarget]
            let hashes: [String]
            let groups: [[String]]
            let formats: [CloudRasterFormat]
            let parent: UUID?
        }
        return digest(try ConnectionCoding.encoder().encode(Content(kind: kind, targets: targets,
            hashes: outputs.map { digest($0.data) }, groups: outputs.map(\.targetIDs),
            formats: outputs.map(\.format), parent: parent)))
    }

    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func ownerURL(_ id: UUID) -> URL { directory.appending(path: "Locks/\(id.uuidString).owner") }
    private func mediaURL(_ batch: UUID, _ file: UUID) -> URL { directory.appending(path: "Media/\(batch.uuidString)/\(file.uuidString)") }
    private func writeMedia(_ data: Data, batch: UUID, file: UUID) throws {
        let url = mediaURL(batch, file)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func removeMedia(_ id: UUID) throws {
        let url = directory.appending(path: "Media/\(id.uuidString)")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
