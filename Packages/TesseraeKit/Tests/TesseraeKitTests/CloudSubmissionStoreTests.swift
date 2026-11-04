import Foundation
import Testing
@testable import TesseraeKit

struct CloudSubmissionStoreTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000.1234567)

    @Test func decisionCannotDispatchTwiceOrResurrectAfterDelete() throws {
        let fixture = try Fixture()
        let decision = UUID()
        let staged = try fixture.stage(decision, now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        let duplicate = try fixture.stage(decision, now: now.addingTimeInterval(10))
        #expect(duplicate.owner == nil)
        #expect(try fixture.store.accept(duplicate, now: now).owner == nil)
        let claim = try #require(try fixture.claim(accepted.batch, at: now))
        #expect(try fixture.claim(accepted.batch, at: now) == nil)
        try fixture.store.deleteResult(decision, now: now)
        #expect(throws: CloudSubmissionError.decisionClosed) { try fixture.stage(decision, now: now) }
        #expect(try fixture.store.resolve(batchID: decision, taskID: accepted.batch.tasks[0].id,
            claim: claim, results: fixture.generated(), now: now) == false)
        #expect(try fixture.store.history(now: now).isEmpty)
    }

    @Test func sameDecisionDifferentContentIsRejected() throws {
        let fixture = try Fixture()
        let decision = UUID()
        let staged = try fixture.stage(decision, now: now)
        _ = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime(staged) {} }
        #expect(throws: CloudSubmissionError.decisionConflict) {
            try fixture.store.stage(decision: decision, fence: fixture.fence, kind: .photo,
                targets: [fixture.target], outputs: [fixture.output(data: Data([9]))], now: now)
        }
    }

    @Test func liveOwnerIsNotInterruptedByHistory() throws {
        let fixture = try Fixture()
        let staged = try fixture.stage(UUID(), now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        _ = try #require(try fixture.claim(accepted.batch, at: now))
        let read = try fixture.store.result(accepted.batch.id, now: now.addingTimeInterval(600))
        #expect(read.isActive)
        if case .claimed = read.tasks[0].state {} else { Issue.record("Live claim was sealed") }
    }

    @Test func abandonedClaimBecomesUnknownAndCannotBeClaimedAgain() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: true, now: now)
        let restored = try fixture.store.result(batch.id, now: now)
        #expect(!restored.isActive)
        if case .unknown(.interrupted, _) = restored.results.first?.outcome {} else {
            Issue.record("An abandoned claim must be unknown")
        }
        #expect(try fixture.claim(restored, at: now) == nil)
    }

    @Test func unstartedTasksAfterInterruptionAreNotAttempted() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: false, now: now)
        let restored = try fixture.store.result(batch.id, now: now)
        #expect(restored.results == [.init(id: fixture.target.id, outcome: .notAttempted(.interrupted))])
        #expect(try fixture.claim(restored, at: now) == nil)
    }

    @Test(arguments: [false, true])
    func onlyCleanGenerationShortensMedia(warning: Bool) throws {
        let fixture = try Fixture()
        let staged = try fixture.stage(UUID(), now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        let claim = try #require(try fixture.claim(accepted.batch, at: now))
        #expect(try fixture.store.resolve(batchID: accepted.batch.id, taskID: accepted.batch.tasks[0].id,
            claim: claim, results: fixture.generated(warnings: warning ? ["decode warning"] : []),
            now: now.addingTimeInterval(50)))
        let result = try fixture.store.result(accepted.batch.id, now: now.addingTimeInterval(60))
        #expect(abs(result.mediaExpiresAt!.timeIntervalSince(now.addingTimeInterval(warning ? 7 * 86_400 : 86_400 + 50))) < 0.001)
        #expect(abs(result.createdAt.timeIntervalSince(now)) < 0.001)
        #expect(abs(result.resultsExpireAt.timeIntervalSince(now.addingTimeInterval(30 * 86_400))) < 0.001)
    }

    @Test func expiryKeepsResultsUntilThirtyDaysAndClosedDecisionForever() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: true, now: now)
        let result = try fixture.store.result(batch.id, now: now.addingTimeInterval(7 * 86_400))
        #expect(!result.results.isEmpty)
        #expect(throws: CloudSubmissionError.mediaUnavailable) {
            try fixture.store.media(result, raster: result.tasks[0].raster!, now: now.addingTimeInterval(7 * 86_400))
        }
        #expect(try fixture.store.history(now: now.addingTimeInterval(30 * 86_400)).isEmpty)
        #expect(throws: CloudSubmissionError.decisionClosed) {
            try fixture.stage(batch.id, now: now.addingTimeInterval(31 * 86_400))
        }
    }

    @Test func manualResendConsumesRevisionAndInheritsMediaClock() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: true, now: now)
        let source = try fixture.store.result(batch.id, now: now)
        let selection = CloudResendSelection(targetIDs: [fixture.target.id], confirmsPossibleDuplicates: true)
        let first = try fixture.store.stageResend(decision: UUID(), sourceID: source.id,
            expectedRevision: source.revision, selection: selection, fence: fixture.fence, now: now.addingTimeInterval(100))
        let second = try fixture.store.stageResend(decision: UUID(), sourceID: source.id,
            expectedRevision: source.revision, selection: selection, fence: fixture.fence, now: now.addingTimeInterval(100))
        defer { withExtendedLifetime((first, second)) {} }
        let accepted = try fixture.store.accept(first, now: now.addingTimeInterval(100))
        #expect(accepted.batch.mediaExpiresAt == source.mediaExpiresAt)
        #expect(accepted.batch.parentID == source.id)
        #expect(throws: CloudSubmissionError.resultChanged) { try fixture.store.accept(second, now: now.addingTimeInterval(100)) }
        #expect(try fixture.store.result(source.id, now: now).results == source.results)
    }

    @Test func identicalResendDecisionDoesNotNeedOldMediaOrRepublish() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: true, now: now)
        let source = try fixture.store.result(batch.id, now: now)
        let decision = UUID()
        let selection = CloudResendSelection(targetIDs: [fixture.target.id], confirmsPossibleDuplicates: true)
        let staged = try fixture.store.stageResend(decision: decision, sourceID: source.id,
            expectedRevision: source.revision, selection: selection, fence: fixture.fence, now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        try fixture.store.deleteResult(source.id, now: now)
        let duplicate = try fixture.store.stageResend(decision: decision, sourceID: source.id,
            expectedRevision: source.revision, selection: selection, fence: fixture.fence, now: now)
        #expect(duplicate.owner == nil)
        #expect(try fixture.store.accept(duplicate, now: now).owner == nil)
        try fixture.store.deleteResult(decision, now: now)
        #expect(throws: CloudSubmissionError.decisionClosed) {
            try fixture.store.stageResend(decision: decision, sourceID: source.id,
                expectedRevision: source.revision, selection: selection, fence: fixture.fence, now: now)
        }
    }

    @Test func deletingMediaCannotRecreateItFromLateSuccess() throws {
        let fixture = try Fixture()
        let staged = try fixture.stage(UUID(), now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        let claim = try #require(try fixture.claim(accepted.batch, at: now))
        try fixture.store.deleteMedia(accepted.batch.id, now: now)
        #expect(try fixture.store.resolve(batchID: accepted.batch.id, taskID: accepted.batch.tasks[0].id,
            claim: claim, results: fixture.generated(), now: now) == false)
        let result = try fixture.store.result(accepted.batch.id, now: now)
        #expect(throws: CloudSubmissionError.mediaUnavailable) {
            try fixture.store.media(result, raster: result.tasks[0].raster!, now: now)
        }
    }

    @Test func staleHandleCannotReadResidualBytesAfterLogicalDeletion() throws {
        let fixture = try Fixture()
        let staged = try fixture.stage(UUID(), now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        let folder = fixture.store.directory.appending(path: "Media/\(accepted.batch.id.uuidString)")
        let raster = try #require(accepted.batch.tasks[0].raster)
        let bytesURL = folder.appending(path: raster.fileID.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        do { try fixture.store.deleteMedia(accepted.batch.id, now: now) }
        catch { /* Logical deletion must remain authoritative when physical cleanup fails. */ }
        #expect(FileManager.default.fileExists(atPath: bytesURL.path))
        #expect(throws: CloudSubmissionError.mediaUnavailable) {
            try fixture.store.media(accepted.batch, raster: raster, now: now)
        }
        try? fixture.store.deleteResult(accepted.batch.id, now: now)
        #expect(throws: CloudSubmissionError.mediaUnavailable) {
            try fixture.store.media(accepted.batch, raster: raster, now: now)
        }
    }

    @Test func unknownRequiresExplicitConfirmation() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: true, now: now)
        let source = try fixture.store.result(batch.id, now: now)
        #expect(throws: CloudSubmissionError.duplicateConfirmationRequired) {
            try fixture.store.stageResend(decision: UUID(), sourceID: source.id,
                expectedRevision: source.revision,
                selection: .init(targetIDs: [fixture.target.id], confirmsPossibleDuplicates: false),
                fence: fixture.fence, now: now)
        }
    }

    @Test func stopWinsAgainstNextClaimAndLateCompletion() throws {
        let fixture = try Fixture()
        let staged = try fixture.stage(UUID(), now: now)
        let accepted = try fixture.store.accept(staged, now: now)
        defer { withExtendedLifetime((staged, accepted)) {} }
        let claim = try #require(try fixture.claim(accepted.batch, at: now))
        try fixture.store.stop(accepted.batch.id, reason: .connectionChanged, now: now)
        #expect(try fixture.store.resolve(batchID: accepted.batch.id, taskID: accepted.batch.tasks[0].id,
            claim: claim, results: fixture.generated(), now: now) == false)
        #expect(try fixture.claim(accepted.batch, at: now) == nil)
    }

    @Test func sameRawIDsInAnotherAccountCannotReadResults() throws {
        let fixture = try Fixture()
        let batch = try fixture.abandoned(claim: false, now: now)
        let other = try CloudSubmissionStore(directory: fixture.root,
            identity: .cloud(issuer: URL(string: "https://cloud.example")!, userID: "B", tenantID: "tenant"))
        #expect(try other.history(now: now).isEmpty)
        #expect(throws: CloudSubmissionError.missingResult) { try other.result(batch.id, now: now) }
    }

    private struct Fixture {
        let root: URL
        let store: CloudSubmissionStore
        let fence: ConnectionFence
        let target: CloudSubmissionTarget
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            let identity = ConnectionIdentity.cloud(issuer: URL(string: "https://cloud.example")!, userID: "A", tenantID: "tenant")
            store = try CloudSubmissionStore(directory: root, identity: identity)
            fence = .init(connectionID: identity.id, epoch: UUID())
            target = .init(id: "same-id", name: "Display", geometry: try .init(width: 160, height: 96))
        }
        func output(data: Data = Data([1, 2, 3])) -> CloudPhotoOutput {
            .init(data: data, format: .png, geometry: target.geometry, targetIDs: [target.id])
        }
        func stage(_ id: UUID, now: Date) throws -> CloudStagedBatch {
            try store.stage(decision: id, fence: fence, kind: .photo, targets: [target], outputs: [output()], now: now)
        }
        func claim(_ batch: CloudSubmissionBatch, at now: Date) throws -> CloudSubmissionClaim? {
            guard case .active(let run) = batch.execution else { return nil }
            return try store.claim(batchID: batch.id, taskID: batch.tasks[0].id, runID: run, fence: fence, now: now)
        }
        func abandoned(claim: Bool, now: Date) throws -> CloudSubmissionBatch {
            let staged = try stage(UUID(), now: now)
            let accepted = try store.accept(staged, now: now)
            if claim { _ = try self.claim(accepted.batch, at: now) }
            return accepted.batch
        }
        func generated(warnings: [String] = []) -> [CloudTargetResult] {
            [.init(id: target.id, outcome: .generated(.init(digest: String(repeating: "a", count: 32),
                bytes: 128, renderedAt: nil, pageID: nil), warnings: warnings))]
        }
    }
}
