import Foundation

public enum ActivityReconciliation {
    public static func visibleJobs(
        _ jobs: [PushJob],
        historyItems: [HistoryItem],
        now: Date = Date(),
        terminalVisibility: TimeInterval = 120,
        legacyCorrelationWindow: TimeInterval = 120
    ) -> [PushJob] {
        let historyByID = Dictionary(
            uniqueKeysWithValues: historyItems.map { ($0.id, $0) }
        )
        var consumedHistoryIDs = Set<String>()
        var reconciledJobIDs = Set<String>()

        for job in jobs where job.isTerminal {
            let correlatedIDs = job.result?.historyEventIDs ?? []
            let matchingIDs = correlatedIDs.filter {
                historyByID[$0] != nil
            }
            guard !matchingIDs.isEmpty else { continue }
            reconciledJobIDs.insert(job.id)
            consumedHistoryIDs.formUnion(matchingIDs)
        }

        let legacyJobs = jobs
            .filter {
                $0.isTerminal
                    && !reconciledJobIDs.contains($0.id)
                    && ($0.result?.historyEventIDs?.isEmpty ?? true)
                    && $0.status == .succeeded
                    && $0.result?.status == .published
            }
            .sorted { $0.createdAt > $1.createdAt }

        for job in legacyJobs {
            let candidate = historyItems
                .filter {
                    !consumedHistoryIDs.contains($0.id)
                        && legacyMatch(
                            job,
                            historyItem: $0,
                            window: legacyCorrelationWindow
                        )
                }
                .min {
                    abs($0.createdAt.timeIntervalSince(job.createdAt))
                        < abs($1.createdAt.timeIntervalSince(job.createdAt))
                }

            guard let candidate else { continue }
            reconciledJobIDs.insert(job.id)
            consumedHistoryIDs.insert(candidate.id)
        }

        return jobs.filter { job in
            guard job.isTerminal else { return true }
            guard !reconciledJobIDs.contains(job.id) else { return false }
            return now.timeIntervalSince(job.createdAt) < terminalVisibility
        }
    }

    public static func displayNames(
        for item: HistoryItem,
        from displays: [DisplaySummary]
    ) -> [String] {
        let names = item.deviceIDs.compactMap { id in
            displays.first(where: { $0.id == id })?.name
        }
        if !names.isEmpty {
            return names
        }

        guard item.deviceIDs.isEmpty, item.source == "button" else {
            return []
        }
        let matchingDisplays = displays.filter {
            equivalentLabel($0.name, item.label)
        }
        guard matchingDisplays.count == 1 else {
            return []
        }
        return [matchingDisplays[0].name]
    }

    private static func legacyMatch(
        _ job: PushJob,
        historyItem: HistoryItem,
        window: TimeInterval
    ) -> Bool {
        guard
            publishedHistoryStatuses.contains(historyItem.status),
            historyItem.source == expectedHistorySource(for: job.kind),
            equivalentLabel(job.label, historyItem.label),
            !job.targetDeviceIDs.isEmpty,
            Set(job.targetDeviceIDs) == Set(historyItem.deviceIDs),
            abs(historyItem.createdAt.timeIntervalSince(job.createdAt))
                <= window
        else {
            return false
        }
        return true
    }

    private static func expectedHistorySource(
        for kind: PushJobKind
    ) -> String {
        switch kind {
        case .dashboardPush, .imagePush:
            "companion"
        case .historyResend:
            "resend"
        }
    }

    private static func equivalentLabel(
        _ lhs: String?,
        _ rhs: String
    ) -> Bool {
        guard let lhs else { return false }
        return lhs.trimmingCharacters(in: .whitespacesAndNewlines)
            .compare(
                rhs.trimmingCharacters(in: .whitespacesAndNewlines),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
    }

    private static let publishedHistoryStatuses = Set([
        "sent",
        "published",
        "succeeded",
        "no_change",
    ])
}
