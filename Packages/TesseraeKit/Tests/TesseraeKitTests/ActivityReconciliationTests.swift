import Foundation
import Testing
@testable import TesseraeKit

@Suite("Activity reconciliation")
struct ActivityReconciliationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("Exact History IDs hide their completed Job")
    func exactHistoryIDs() {
        let history = historyItem(id: "42")
        let job = pushJob(
            id: "job-exact",
            historyEventIDs: ["42"]
        )

        #expect(
            ActivityReconciliation.visibleJobs(
                [job],
                historyItems: [history],
                now: now
            ).isEmpty
        )
    }

    @Test("A strict legacy match hides a Job without History IDs")
    func legacyFallback() {
        let history = historyItem(
            id: "43",
            createdAt: now.addingTimeInterval(8)
        )
        let job = pushJob(id: "job-legacy")

        #expect(
            ActivityReconciliation.visibleJobs(
                [job],
                historyItems: [history],
                now: now.addingTimeInterval(10)
            ).isEmpty
        )
    }

    @Test("One History row only reconciles one legacy Job")
    func consumesHistoryOnce() {
        let history = historyItem(
            id: "44",
            createdAt: now.addingTimeInterval(8)
        )
        let first = pushJob(id: "job-newer")
        let second = pushJob(
            id: "job-older",
            createdAt: now.addingTimeInterval(-1)
        )

        let visible = ActivityReconciliation.visibleJobs(
            [first, second],
            historyItems: [history],
            now: now.addingTimeInterval(10)
        )

        #expect(visible.map(\.id) == ["job-older"])
    }

    @Test("A different display does not reconcile")
    func rejectsLooseMatch() {
        let history = historyItem(
            id: "45",
            deviceIDs: ["hall"]
        )
        let job = pushJob(id: "job-other-device")

        #expect(
            ActivityReconciliation.visibleJobs(
                [job],
                historyItems: [history],
                now: now.addingTimeInterval(10)
            ).map(\.id) == ["job-other-device"]
        )
    }

    @Test("Link Jobs reconcile with their canonical History source")
    func linkSources() {
        let imageURLJob = pushJob(id: "job-url", kind: .imageURLPush)
        let webpageJob = pushJob(id: "job-webpage", kind: .webpagePush)
        let history = [
            historyItem(id: "48", source: "url"),
            historyItem(id: "49", source: "webpage"),
        ]

        #expect(
            ActivityReconciliation.visibleJobs(
                [imageURLJob, webpageJob],
                historyItems: history,
                now: now.addingTimeInterval(10)
            ).isEmpty
        )
    }

    @Test("A failed Job replaces its targetless server History row")
    func failedJobKeepsTargetIdentity() {
        let message = "dashboard targets none of the requested device(s)"
        let history = historyItem(
            id: "50",
            deviceIDs: [],
            label: "Album Art · Canvas",
            status: "failed",
            error: message
        )
        let job = failedPushJob(
            id: "job-failed",
            label: "Album Art · Canvas",
            error: message
        )

        #expect(
            ActivityReconciliation.visibleJobs(
                [job],
                historyItems: [history],
                now: now.addingTimeInterval(10)
            ).map(\.id) == ["job-failed"]
        )
        #expect(
            ActivityReconciliation.visibleHistoryItems(
                [history],
                jobs: [job]
            ).isEmpty
        )
    }

    @Test("Different failed operations remain visible")
    func failedJobRejectsLooseMatch() {
        let history = historyItem(
            id: "51",
            deviceIDs: [],
            label: "Album Art · Canvas",
            status: "failed",
            error: "render timed out"
        )
        let job = failedPushJob(
            id: "job-other-failure",
            label: "Album Art · Canvas",
            error: "dashboard targets none of the requested device(s)"
        )

        #expect(
            ActivityReconciliation.visibleHistoryItems(
                [history],
                jobs: [job]
            ).map(\.id) == ["51"]
        )
    }

    @Test("Fetched button History resolves one matching display name")
    func fetchedDisplayFallback() {
        let history = historyItem(
            id: "46",
            source: "button",
            deviceIDs: [],
            label: "Living Room Frame",
            status: "fetched"
        )
        let displays = [
            display(id: "living-room", name: "Living Room Frame"),
            display(id: "kitchen", name: "Kitchen"),
        ]

        #expect(
            ActivityReconciliation.displayNames(
                for: history,
                from: displays
            ) == ["Living Room Frame"]
        )
    }

    @Test("Ambiguous button labels do not invent a target")
    func fetchedDisplayFallbackRejectsAmbiguity() {
        let history = historyItem(
            id: "47",
            source: "button",
            deviceIDs: [],
            label: "Frame",
            status: "fetched"
        )
        let displays = [
            display(id: "one", name: "Frame"),
            display(id: "two", name: "Frame"),
        ]

        #expect(
            ActivityReconciliation.displayNames(
                for: history,
                from: displays
            ).isEmpty
        )
    }

    private func pushJob(
        id: String,
        kind: PushJobKind = .dashboardPush,
        createdAt: Date? = nil,
        historyEventIDs: [String]? = nil
    ) -> PushJob {
        PushJob(
            id: id,
            kind: kind,
            status: .succeeded,
            label: "Emby Poster · Canvas QA",
            targetDeviceIDs: ["living-room"],
            createdAt: createdAt ?? now,
            updatedAt: (createdAt ?? now).addingTimeInterval(8),
            result: PushJobResult(
                status: .published,
                deviceIDs: ["living-room"],
                historyEventIDs: historyEventIDs
            )
        )
    }

    private func failedPushJob(
        id: String,
        label: String,
        error: String,
        createdAt: Date? = nil
    ) -> PushJob {
        PushJob(
            id: id,
            kind: .dashboardPush,
            status: .failed,
            label: label,
            targetDeviceIDs: ["blue-picpak"],
            createdAt: createdAt ?? now,
            updatedAt: (createdAt ?? now).addingTimeInterval(1),
            error: PushJobFailure(
                code: "render_failed",
                message: error
            )
        )
    }

    private func historyItem(
        id: String,
        createdAt: Date? = nil,
        source: String = "companion",
        deviceIDs: [String] = ["living-room"],
        label: String = "Emby Poster · Canvas QA",
        status: String = "sent",
        error: String? = nil
    ) -> HistoryItem {
        HistoryItem(
            id: id,
            createdAt: createdAt ?? now,
            source: source,
            label: label,
            deviceIDs: deviceIDs,
            status: status,
            error: error,
            previewAvailable: true,
            resendable: true
        )
    }

    private func display(id: String, name: String) -> DisplaySummary {
        DisplaySummary(
            id: id,
            name: name,
            kind: "seeed_reterminal_e1004",
            panel: PanelProfile(
                width: 1200,
                height: 1600,
                gamut: "spectra-6",
                orientation: "portrait"
            ),
            freshness: .fresh
        )
    }
}
