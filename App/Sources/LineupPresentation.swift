import Foundation
import TesseraeKit

enum LineupRoute: Hashable {
    case lineup(id: String, displayID: String?)
    case display(id: String)
}

enum LineupNavigationState: Equatable {
    case noTargets
    case noReports(missing: Int)
    case samePage(id: String, missing: Int)
    case mixedPages(missing: Int)

    init(targetIDs: Set<String>, current: [LineupCurrent]) {
        guard !targetIDs.isEmpty else { self = .noTargets; return }
        let reports = current.filter { targetIDs.contains($0.deviceID) }
        let missing = targetIDs.subtracting(reports.map(\.deviceID)).count
        let pages = Set(reports.map(\.pageID))
        if pages.isEmpty { self = .noReports(missing: missing) }
        else if pages.count == 1, let page = pages.first {
            self = .samePage(id: page, missing: missing)
        } else { self = .mixedPages(missing: missing) }
    }

    func title(dashboards: [LineupDashboard]) -> String {
        switch self {
        case .noTargets:
            return String(localized: "Select a target")
        case .noReports:
            return String(localized: "Schedule step not reported")
        case let .samePage(id, missing):
            let name = dashboards.first { $0.pageID == id }?.name ?? id
            let title = String(localized: "Schedule step: \(name)")
            return missing == 0 ? title : title + " · " + String(localized: "\(missing) targets not reported")
        case let .mixedPages(missing):
            let title = String(localized: "Different schedule steps")
            return missing == 0 ? title : title + " · " + String(localized: "\(missing) targets not reported")
        }
    }
}

struct LineupStepNavigation {
    let matchingTargetIDs: Set<String>
    let allSelectedTargetsMatch: Bool

    init(pageID: String, targetIDs: Set<String>, current: [LineupCurrent]) {
        matchingTargetIDs = Set(current.filter {
            targetIDs.contains($0.deviceID) && $0.pageID == pageID
        }.map(\.deviceID))
        allSelectedTargetsMatch = !targetIDs.isEmpty && matchingTargetIDs == targetIDs
    }
}

struct PlannedDisplayEvent: Identifiable {
    let displayID: String
    let displayName: String
    let event: DeviceUpcomingEvent
    let generatedAt: Date
    let throughAt: Date
    let timezone: String

    var id: String { "\(displayID)|\(event.id)" }
}

struct DisplayPlanProjection: Identifiable {
    enum Availability: Equatable {
        case unsupported
        case unavailable
        case notLoaded
        case available
        case expired
    }

    let id: String
    let displayName: String
    let availability: Availability
    let response: DeviceUpcomingResponse?
    let events: [PlannedDisplayEvent]
    let isRefreshing: Bool
    let error: String?
    let now: Date

    var next: PlannedDisplayEvent? {
        guard availability == .available else { return nil }
        return events.first { $0.event.scheduledAt > now }
    }

    var status: String {
        switch availability {
        case .unsupported: String(localized: "Planned updates are not supported by this server.")
        case .unavailable: String(localized: "Assigned display is not available")
        case .notLoaded: isRefreshing
            ? String(localized: "Loading scheduled updates…")
            : error ?? String(localized: "Planned updates not loaded")
        case .expired: String(localized: "Previous projection has expired")
        case .available: next == nil
            ? String(localized: "No matching update within the projection")
            : String(localized: "Next planned update")
        }
    }
}

func displayPlanProjections(
    deviceIDs: [String],
    displays: [DisplaySummary],
    supported: Bool,
    responses: [String: DeviceUpcomingResponse],
    refreshing: Set<String>,
    errors: [String: String],
    lineupID: String? = nil,
    now: Date = Date()
) -> [DisplayPlanProjection] {
    let known = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0.name) })
    var seen: Set<String> = []
    return deviceIDs.filter { seen.insert($0).inserted }.map { id in
        let response = responses[id].flatMap { $0.deviceID == id ? $0 : nil }
        let availability: DisplayPlanProjection.Availability
        if known[id] == nil { availability = .unavailable }
        else if !supported { availability = .unsupported }
        else if let response { availability = response.throughAt <= now ? .expired : .available }
        else { availability = .notLoaded }
        let events: [PlannedDisplayEvent]
        if let response {
            events = response.events.filter {
                (lineupID == nil || $0.lineupID == lineupID)
                    && $0.scheduledAt >= response.generatedAt
                    && $0.scheduledAt <= response.throughAt
            }.sorted { $0.scheduledAt < $1.scheduledAt }.map {
                PlannedDisplayEvent(
                    displayID: id, displayName: known[id] ?? id, event: $0,
                    generatedAt: response.generatedAt, throughAt: response.throughAt,
                    timezone: response.timezone
                )
            }
        } else { events = [] }
        return DisplayPlanProjection(
            id: id, displayName: known[id] ?? id, availability: availability,
            response: response, events: events,
            isRefreshing: refreshing.contains(id), error: errors[id], now: now
        )
    }
}

func plannedEventTime(_ event: PlannedDisplayEvent) -> String {
    projectionDateText(event.event.scheduledAt, timezone: event.timezone)
}

func projectionDateText(_ date: Date, timezone: String) -> String {
    let formatter = DateFormatter()
    formatter.timeZone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0)
    formatter.setLocalizedDateFormatFromTemplate("MMM d E HH:mm z")
    return formatter.string(from: date)
}

func lineupScheduleSummary(_ lineup: Lineup) -> String {
    switch lineup.intent {
    case .daily:
        lineup.firesAt.map { String(localized: "Daily at \($0)") } ?? String(localized: "Daily")
    case .interval:
        lineup.intervalMinutes.map { String(localized: "Every \($0) min") } ?? String(localized: "Interval")
    case .cycle:
        lineup.anchor.map { String(localized: "Starts at \($0)") } ?? String(localized: "Timed rotation")
    case .manual: String(localized: "Manual")
    case nil:
        switch lineup.advance {
        case .manual: String(localized: "Manual")
        case .timer: String(localized: "Timer")
        case .both: String(localized: "Manual and timer")
        }
    }
}

func lineupDaysSummary(_ days: [Int]?) -> String? {
    guard let days else { return nil }
    let normalized = Set(days)
    if normalized == Set(0...6) { return String(localized: "Every day") }
    if normalized == Set(0...4) { return String(localized: "Weekdays") }
    let names = [String(localized: "Mon"), String(localized: "Tue"), String(localized: "Wed"),
                 String(localized: "Thu"), String(localized: "Fri"), String(localized: "Sat"), String(localized: "Sun")]
    return normalized.sorted().compactMap { names.indices.contains($0) ? names[$0] : nil }.joined(separator: ", ")
}

func plannedCertaintyTitle(_ certainty: DeviceUpcomingCertainty) -> String {
    switch certainty {
    case .scheduled: String(localized: "Scheduled")
    case .conditional: String(localized: "Conditional")
    case .estimated: String(localized: "Estimated")
    }
}
