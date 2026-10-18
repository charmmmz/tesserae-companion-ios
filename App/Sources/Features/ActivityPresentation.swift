import Foundation
import TesseraeKit

/// Server outcomes describe delivery, not an acknowledgement from the physical screen.
struct ActivityStatusPresentation {
    enum Kind: Equatable, Sendable {
        case queued, sending, ready, partlyReady, quiet, busy, paused
        case actionSent, webhookSent, homeAssistantSent, refreshRequested
        case unchanged, passed, duplicate, noChangeNeeded, replaced
        case unassigned, noDisplays, notFound, noContent, noAction, outdated
        case blocked, adjusted, fallback, failed, homeAssistantFailed
        case unknown(String)

        var label: String {
            switch self {
            case .queued: String(localized: "Queued")
            case .sending: String(localized: "Sending")
            case .ready: String(localized: "Ready for Display")
            case .partlyReady: String(localized: "Some Displays Ready")
            case .quiet: String(localized: "Quiet Hours")
            case .busy: String(localized: "Busy")
            case .paused: String(localized: "Paused")
            case .actionSent: String(localized: "Action Sent")
            case .webhookSent: String(localized: "Webhook Triggered")
            case .homeAssistantSent: String(localized: "Home Assistant Triggered")
            case .refreshRequested: String(localized: "Refresh Requested")
            case .unchanged: String(localized: "Unchanged")
            case .passed: String(localized: "Passed")
            case .duplicate: String(localized: "Duplicate Ignored")
            case .noChangeNeeded: String(localized: "Nothing to Change")
            case .replaced: String(localized: "Replaced")
            case .unassigned: String(localized: "No Action Set")
            case .noDisplays: String(localized: "No Displays")
            case .notFound: String(localized: "Content Not Found")
            case .noContent: String(localized: "No Current Content")
            case .noAction: String(localized: "No Action Here")
            case .outdated: String(localized: "Older Content")
            case .blocked: String(localized: "Action Blocked")
            case .adjusted: String(localized: "Adjusted")
            case .fallback: String(localized: "Fallback Used")
            case .failed: String(localized: "Failed")
            case .homeAssistantFailed: String(localized: "Home Assistant Failed")
            case .unknown(let value): value.isEmpty ? String(localized: "Unknown") : value
            }
        }

        var explanation: String? {
            switch self {
            case .partlyReady:
                String(localized: "Some displays were skipped or could not receive this update.")
            case .quiet:
                String(localized: "Skipped during quiet hours.")
            case .busy:
                String(localized: "Another update was in progress.")
            case .paused:
                String(localized: "The server kept the current content.")
            case .unchanged:
                String(localized: "The server found no new content.")
            case .noChangeNeeded:
                String(localized: "This action did not require an update.")
            case .replaced:
                String(localized: "A newer update took its place.")
            case .unassigned:
                String(localized: "This control has no assigned action.")
            case .noDisplays:
                String(localized: "Choose a display for this content.")
            case .notFound:
                String(localized: "The requested content is no longer available.")
            case .noContent:
                String(localized: "No content was available for this action.")
            case .outdated:
                String(localized: "This action referred to content that has been replaced.")
            case .blocked:
                String(localized: "The server did not allow this action.")
            case .unknown:
                String(localized: "The server reported an unrecognized status.")
            default:
                nil
            }
        }

        var symbol: String {
            switch self {
            case .queued, .busy: "clock"
            case .sending: "arrow.triangle.2.circlepath"
            case .ready, .partlyReady: "paperplane.fill"
            case .actionSent, .webhookSent: "paperplane.fill"
            case .homeAssistantSent: "house.fill"
            case .refreshRequested: "arrow.down.circle.fill"
            case .unchanged, .passed: "checkmark.circle"
            case .quiet: "moon.fill"
            case .paused: "pause.circle.fill"
            case .duplicate: "doc.on.doc.fill"
            case .noChangeNeeded: "minus.circle.fill"
            case .replaced: "arrow.right.circle.fill"
            case .noDisplays, .noContent: "rectangle.slash"
            case .notFound: "magnifyingglass"
            case .noAction: "scope"
            case .outdated: "clock.fill"
            case .blocked: "hand.raised.fill"
            case .adjusted: "arrow.left.arrow.right.circle.fill"
            case .fallback: "arrow.turn.down.right"
            case .failed, .homeAssistantFailed: "exclamationmark.triangle.fill"
            case .unassigned, .unknown: "questionmark.circle.fill"
            }
        }
    }

    let kind: Kind
    let detail: String?
    let needsAttention: Bool

    var label: String { kind.label }
    var symbol: String { kind.symbol }
    var explanation: String? { detail ?? kind.explanation }

    init(history item: HistoryItem) {
        let raw = item.status.trimmingCharacters(in: .whitespacesAndNewlines)
        kind = switch raw.lowercased() {
        case "sent", "published", "succeeded": .ready
        case "dispatched": .actionSent
        case "webhook_dispatched": .webhookSent
        case "ha_dispatched": .homeAssistantSent
        case "fetched": .refreshRequested
        case "no_change": .unchanged
        case "passed": .passed
        case "quiet": .quiet
        case "busy": .busy
        case "held": .paused
        case "deduped": .duplicate
        case "noop": .noChangeNeeded
        case "superseded": .replaced
        case "unmapped": .unassigned
        case "unbound": .noDisplays
        case "not_found": .notFound
        case "no_frame": .noContent
        case "no_target": .noAction
        case "stale": .outdated
        case "blocked": .blocked
        case "shifted": .adjusted
        case "fallback": .fallback
        case "failed", "error": .failed
        case "ha_failed": .homeAssistantFailed
        default: .unknown(raw)
        }
        detail = Self.nonempty(item.error)
        // Held/quiet and other normal outcomes may carry a reason in `error`.
        // Unknown outcomes only need attention when the server provides an error.
        needsAttention = switch kind {
        case .failed, .homeAssistantFailed, .blocked, .notFound, .noDisplays: true
        case .unknown: detail != nil
        default: false
        }
    }

    init(job: PushJob) {
        kind = switch job.status {
        case .accepted: .queued
        case .running: .sending
        case .failed: .failed
        case .succeeded:
            if job.result?.status == .quiet {
                .quiet
            } else if let result = job.result,
                      !Set(job.targetDeviceIDs).isSubset(of: Set(result.deviceIDs)) {
                .partlyReady
            } else if job.result?.status == .published {
                .ready
            } else {
                .unknown("")
            }
        }
        detail = Self.nonempty(job.error?.message)
        needsAttention = job.status == .failed || detail != nil
    }

    private static func nonempty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum ActivityFilter: Hashable, Sendable {
    case all
    case needsAttention

    var label: String {
        switch self {
        case .all: String(localized: "All")
        case .needsAttention: String(localized: "Needs Attention")
        }
    }

    func includes(_ presentation: ActivityStatusPresentation) -> Bool {
        self == .all || presentation.needsAttention
    }

    func includesQueuedImage(_ request: SharedImageRequest, isActive: Bool) -> Bool {
        self == .all || (!isActive && request.status != .submitting)
    }

    func includesQueuedLink(_ request: SharedLinkRequest, isActive: Bool) -> Bool {
        self == .all || (!isActive && request.status != .submitting)
    }
}

/// Reconcile before filtering so switching filters cannot resurrect duplicates.
struct ActivityTimeline {
    let jobs: [PushJob]
    let history: [HistoryItem]

    init(
        jobs: [PushJob],
        history: [HistoryItem],
        supportsHistory: Bool,
        filter: ActivityFilter,
        now: Date = Date()
    ) {
        let reconciledJobs = supportsHistory
            ? ActivityReconciliation.visibleJobs(jobs, historyItems: history, now: now)
            : jobs
        // A job that has aged out cannot replace its canonical failure record.
        let reconciledHistory = supportsHistory
            ? ActivityReconciliation.visibleHistoryItems(history, jobs: reconciledJobs)
            : history
        self.jobs = reconciledJobs.filter {
            filter.includes(ActivityStatusPresentation(job: $0))
        }
        self.history = reconciledHistory.filter {
            filter.includes(ActivityStatusPresentation(history: $0))
        }
    }
}
