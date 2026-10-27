import Foundation
import Testing
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
@Suite("Send completion")
struct SendSubmissionTests {
    enum Outcome: CaseIterable {
        case success, jobFailure, pollingFailure, offline, expiredJob
    }

    @Test("Only completed sends succeed", arguments: Outcome.allCases, ["groupedPhoto", "photo", "link"])
    func completion(outcome: Outcome, source: String) async throws {
        let fetchError: TesseraeClientError? = switch outcome {
        case .pollingFailure: .server(code: "temporary_error", message: "Polling failed", requestID: nil)
        case .expiredJob: .server(code: "not_found", message: "No job with that id.", requestID: nil)
        case .offline: .transport("Network connection lost")
        default: nil
        }
        let client = MockTesseraeClient(
            latency: .zero,
            jobFetchError: fetchError,
            jobFailure: outcome == .jobFailure ? PushJobFailure(code: "render_failed", message: "Rendering failed") : nil
        )
        let model = await makeModel(client)
        let sent: Bool
        switch source {
        case "groupedPhoto":
            sent = await sendPhoto(model)
        case "photo":
            sent = await model.sendImage(data: photo, fit: .fill,
                deviceIDs: ["e1004-desk"], contentType: "image/jpeg")
        default:
            sent = await model.sendLink(url: try #require(URL(string: "https://example.com/photo")),
                kind: .imageURL, fit: .fill, deviceIDs: ["e1004-desk"])
        }
        #expect(sent == (outcome == .success))
        #expect(model.activeOperationIDs.isEmpty)
        if outcome == .success || outcome == .offline {
            #expect(model.lastError == nil)
        } else {
            #expect(model.lastError != nil)
        }
        if outcome == .jobFailure { #expect(model.lastError == "Rendering failed") }
        if outcome == .offline { #expect(model.connectionHealth == .offline) }
    }

    @Test("A partially accepted photo batch retries without duplicating accepted jobs")
    func partialBatchRetry() async throws {
        let client = MockTesseraeClient(latency: .zero, imageSendErrors: [
            .server(code: "temporary_error", message: "Try again", requestID: nil)
        ])
        let model = await makeModel(client)
        #expect(await sendPhoto(model) == false)
        #expect(model.jobs.count == 1)
        model.lastError = nil
        #expect(await sendPhoto(model) == true)
        #expect(model.jobs.count == 2)
        #expect(model.jobs.allSatisfy { $0.status == .succeeded })
        #expect(model.lastError == nil)
    }

    @Test("Submission and progress survive closing the composer and reject duplicate starts")
    func submissionSurvivesClosingComposer() async throws {
        let submission = SendSubmissionSession()
        let center = TesseraeMessageCenter()
        let root = UUID()
        let composer = UUID()
        center.activateHost(id: root)
        center.activateHost(id: composer)
        let gate = AsyncStream<Void>.makeStream()
        let task = try #require(submission.start(messageCenter: center, confirmation: "Sent") {
            var iterator = gate.stream.makeAsyncIterator()
            _ = await iterator.next()
            return nil
        })
        #expect(submission.isSubmitting)
        #expect(center.currentMessage?.kind == .progress(fraction: nil))
        center.deactivateHost(id: composer)
        #expect(center.currentMessage?.accessibilityIdentifier == "send-progress-capsule")
        #expect(submission.start(messageCenter: center, confirmation: "Duplicate", operation: { nil }) == nil)
        gate.continuation.yield(())
        gate.continuation.finish()
        await task.value
        #expect(!submission.isSubmitting)
        #expect(center.currentMessage?.kind == .success)
        #expect(center.currentMessage?.text == "Sent")
    }

    @Test("A failed submission retains its operation for an explicit capsule retry")
    func failureRetriesFromCapsule() async throws {
        let submission = SendSubmissionSession()
        let center = TesseraeMessageCenter()
        let retried = AsyncStream<Void>.makeStream()
        var attempts = 0
        let task = try #require(submission.start(messageCenter: center, confirmation: "Sent") {
            attempts += 1
            if attempts == 1 { return "Try again" }
            retried.continuation.yield(())
            retried.continuation.finish()
            return nil
        })
        await task.value
        #expect(!submission.isSubmitting)
        #expect(center.currentMessage?.kind == .error)
        let retry = try #require(center.currentMessage?.action)
        retry.perform()
        #expect(submission.isSubmitting)
        for await _ in retried.stream { break }
        #expect(attempts == 2)
        #expect(!submission.isSubmitting)
        #expect(center.currentMessage?.kind == .success)
    }

    private func sendPhoto(_ model: AppModel) async -> Bool {
        await model.sendImage(data: photo, fit: .fill,
            targetGroups: [
                ImageSendTargetGroup(id: "portrait", aspectRatio: nil,
                    deviceIDs: ["e1004-desk"], framing: ImageFraming(focusX: 0.7, focusY: 0.4, zoom: 1.6)),
                ImageSendTargetGroup(id: "landscape", aspectRatio: nil,
                    deviceIDs: ["picpak-kitchen"], framing: .centeredFill)
            ],
            idempotencyKeys: ["portrait": "portrait-request", "landscape": "landscape-request"],
            contentType: "image/jpeg")
    }

    private var photo: Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAADIAAAAeCAYAAABuUU38AAAAU0lEQVR42u3PMQ3AIBAAQJxUSxc84KgKagcZWGBiadKViiAkn+aGE3Dpffr8gyQisily3NdcMWoOQURERERERERERGR/pJUzBBERERERERGRgJEPNPv5WtxkAPMAAAAASUVORK5CYII=")!
    }

    private func makeModel(_ client: MockTesseraeClient) async -> AppModel {
        let model = AppModel(
            liveClient: client, demoClient: client,
            credentials: InMemoryCredentialStore(),
            stateStore: InMemoryCompanionStateStore(),
            sendPreferences: InMemoryCompanionSendPreferencesStore(),
            shareQueue: InMemoryShareQueueStore(),
            linkShareQueue: InMemoryLinkShareQueueStore(),
            activityThumbnails: InMemoryActivityThumbnailStore(),
            discovery: StaticDiscoveryService(results: [])
        )
        await model.connectDemo()
        return model
    }
}
