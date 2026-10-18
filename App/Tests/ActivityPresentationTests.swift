import Foundation
import TesseraeKit
import Testing
@testable import Tesserae_Companion

@Suite("Activity status and attention filtering")
struct ActivityPresentationTests {
    @Test("Server delivery outcomes do not claim a physical screen refresh", arguments: [
        ("sent", ActivityStatusPresentation.Kind.ready),
        ("published", .ready), ("succeeded", .ready),
        ("dispatched", .actionSent), ("fetched", .refreshRequested),
        ("webhook_dispatched", .webhookSent), ("ha_dispatched", .homeAssistantSent),
        ("no_change", .unchanged), ("held", .paused),
        ("noop", .noChangeNeeded), ("superseded", .replaced),
        ("  HeLD\n", .paused),
    ])
    func deliveryMeaning(status: String, kind: ActivityStatusPresentation.Kind) {
        let presentation = ActivityStatusPresentation(history: history(status: status))
        #expect(presentation.kind == kind)
        #expect(!presentation.needsAttention)
    }

    @Test("Normal outcomes remain informational even when the server uses error for a reason", arguments: [
        "quiet", "busy", "held", "deduped", "noop", "superseded", "no_change",
        "unmapped", "no_target", "no_frame", "stale", "shifted", "fallback", "passed",
    ])
    func normalReasons(status: String) {
        let presentation = ActivityStatusPresentation(history: history(
            status: status, error: "  all devices manually held  "
        ))
        #expect(!ActivityFilter.needsAttention.includes(presentation))
        #expect(ActivityFilter.all.includes(presentation))
        #expect(presentation.detail == "all devices manually held")
    }

    @Test("Failures and blocked sends need attention even without an error message", arguments: [
        "failed", "error", "ha_failed", "blocked", "not_found", "unbound", " FAILED\n",
    ])
    func failuresNeedAttention(status: String) {
        let presentation = ActivityStatusPresentation(history: history(status: status))
        #expect(presentation.needsAttention)
        #expect(ActivityFilter.needsAttention.includes(presentation))
    }

    @Test("Unknown outcomes are conservative and keep real error details", arguments: [
        (nil as String?, false), ("  \n", false), ("  Device rejected the update.  ", true),
    ])
    func unknownOutcomes(error: String?, needsAttention: Bool) {
        let presentation = ActivityStatusPresentation(history: history(status: "new_server_outcome", error: error))
        #expect(presentation.kind == .unknown("new_server_outcome"))
        #expect(presentation.needsAttention == needsAttention)
        #expect(ActivityFilter.needsAttention.includes(presentation) == needsAttention)
    }

    @Test("Error details survive trimming without replacement by generic copy")
    func failureDetail() {
        let presentation = ActivityStatusPresentation(history: history(
            status: "failed", error: "  Cannot render this image.\n"
        ))
        #expect(presentation.explanation == "Cannot render this image.")
    }

    @Test("Active work does not require manual attention", arguments: [PushJobStatus.accepted, .running])
    func activeJobs(status: PushJobStatus) {
        let presentation = ActivityStatusPresentation(job: job(status: status))
        #expect(!presentation.needsAttention)
        #expect(!ActivityFilter.needsAttention.includes(presentation))
    }

    @Test("A succeeded job without a business result is not assumed to be delivered")
    func missingBusinessResult() {
        let presentation = ActivityStatusPresentation(job: job(status: .succeeded))
        #expect(presentation.kind == .unknown(""))
        #expect(!presentation.needsAttention)
    }

    @Test("Quiet hours are a skipped send rather than a failure")
    func quietJob() {
        let presentation = ActivityStatusPresentation(job: job(
            status: .succeeded,
            result: PushJobResult(status: .quiet, reason: "all_targets_in_quiet_hours", deviceIDs: ["desk"])
        ))
        #expect(presentation.kind == .quiet)
        #expect(!presentation.needsAttention)
    }

    @Test("Partial publication alone cannot distinguish quiet displays from failures")
    func partialPublication() {
        let presentation = ActivityStatusPresentation(job: job(
            status: .succeeded, targets: ["desk", "kitchen"],
            result: PushJobResult(status: .published, deviceIDs: ["desk"])
        ))
        #expect(presentation.kind == .partlyReady)
        #expect(!presentation.needsAttention)
    }

    @Test("Published target IDs are compared as sets")
    func allTargetsPublished() {
        let presentation = ActivityStatusPresentation(job: job(
            status: .succeeded, targets: ["desk", "kitchen", "desk"],
            result: PushJobResult(status: .published, deviceIDs: ["kitchen", "desk"])
        ))
        #expect(presentation.kind == .ready)
    }

    @Test("Retryable local photos stay visible while active submissions are excluded", arguments: [
        (SharedImageRequestStatus.queued, false, true), (.failed, false, true),
        (.submitting, false, false), (.queued, true, false),
        (.failed, true, false), (.submitting, true, false),
    ])
    func queuedPhotos(status: SharedImageRequestStatus, active: Bool, included: Bool) {
        let request = SharedImageRequest(
            instanceID: "server", fileName: "photo.jpg", contentType: "image/jpeg",
            fit: .fit, deviceIDs: ["desk"], status: status
        )
        #expect(ActivityFilter.needsAttention.includesQueuedImage(request, isActive: active) == included)
        #expect(ActivityFilter.all.includesQueuedImage(request, isActive: active))
    }

    @Test("Retryable local links stay visible while active submissions are excluded", arguments: [
        (SharedLinkRequestStatus.queued, false, true), (.failed, false, true),
        (.submitting, false, false), (.queued, true, false),
        (.failed, true, false), (.submitting, true, false),
    ])
    func queuedLinks(status: SharedLinkRequestStatus, active: Bool, included: Bool) throws {
        let request = SharedLinkRequest(
            instanceID: "server", url: try #require(URL(string: "https://example.com")),
            kind: .webpage, fit: .fit, deviceIDs: ["desk"], status: status
        )
        #expect(ActivityFilter.needsAttention.includesQueuedLink(request, isActive: active) == included)
        #expect(ActivityFilter.all.includesQueuedLink(request, isActive: active))
    }

    @Test("A failed target survives alongside a partially successful job")
    func mixedOutcomes() {
        let successful = history(id: "success", status: "sent", devices: ["desk"])
        let failed = history(id: "failure", status: "failed", error: "Render failed", devices: ["kitchen"])
        let partialJob = job(
            status: .succeeded, targets: ["desk", "kitchen"],
            result: PushJobResult(status: .published, deviceIDs: ["desk"], historyEventIDs: ["success"])
        )
        let timeline = ActivityTimeline(
            jobs: [partialJob], history: [successful, failed], supportsHistory: true,
            filter: .needsAttention, now: referenceDate
        )
        #expect(timeline.jobs.isEmpty)
        #expect(timeline.history.map(\.id) == ["failure"])
    }

    @Test("Failed-job deduplication never hides both the job and its history", arguments: [
        (0.0, ["job"], [String]()), (121.0, [String](), ["history"]),
    ])
    func failureDeduplication(age: Double, jobIDs: [String], historyIDs: [String]) {
        let failedJob = job(status: .failed, error: PushJobFailure(code: "render_failed", message: "Render failed"))
        let record = history(status: "failed", error: "Render failed")
        let timeline = ActivityTimeline(
            jobs: [failedJob], history: [record], supportsHistory: true,
            filter: .needsAttention, now: referenceDate.addingTimeInterval(age)
        )
        #expect(timeline.jobs.map(\.id) == jobIDs)
        #expect(timeline.history.map(\.id) == historyIDs)
    }

    @Test("Changing filters retains canonical records without resurrecting jobs", arguments: [
        (ActivityFilter.all, ["history"]), (.needsAttention, [String]()),
    ])
    func filterAfterReconciliation(filter: ActivityFilter, historyIDs: [String]) {
        let timeline = ActivityTimeline(
            jobs: [job(status: .succeeded, result: PushJobResult(
                status: .published, deviceIDs: ["desk"], historyEventIDs: ["history"]
            ))],
            history: [history(status: "sent")], supportsHistory: true,
            filter: filter, now: referenceDate
        )
        #expect(timeline.jobs.isEmpty)
        #expect(timeline.history.map(\.id) == historyIDs)
    }

    @Test("Older servers without history retain failed jobs")
    func noHistoryCapability() {
        let timeline = ActivityTimeline(
            jobs: [job(status: .failed)], history: [], supportsHistory: false,
            filter: .needsAttention, now: referenceDate.addingTimeInterval(600)
        )
        #expect(timeline.jobs.map(\.id) == ["job"])
    }

    private var referenceDate: Date { Date(timeIntervalSince1970: 1_800_000_000) }

    private func history(
        id: String = "history", status: String, error: String? = nil,
        devices: [String] = ["desk"]
    ) -> HistoryItem {
        HistoryItem(
            id: id, createdAt: referenceDate, source: "companion", label: "Weather",
            deviceIDs: devices, status: status, error: error,
            previewAvailable: false, resendable: false
        )
    }

    private func job(
        status: PushJobStatus, targets: [String] = ["desk"],
        result: PushJobResult? = nil, error: PushJobFailure? = nil
    ) -> PushJob {
        PushJob(
            id: "job", kind: .dashboardPush, status: status, label: "Weather",
            targetDeviceIDs: targets, createdAt: referenceDate, updatedAt: referenceDate,
            result: result, error: error
        )
    }
}
