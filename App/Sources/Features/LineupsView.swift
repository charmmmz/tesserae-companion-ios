import SwiftUI
import TesseraeKit

struct LineupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.lineups) { lineup in
                    NavigationLink {
                        LineupDetailView(lineupID: lineup.id)
                    } label: {
                        LineupCard(lineup: lineup)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lineup-card-\(lineup.id)")
                }
            }
            .padding(16)
        }
        .overlay {
            if (model.isRefreshingLineups || model.isRefreshing)
                && model.lineups.isEmpty
            {
                ProgressView("Loading Lineups…")
            } else if model.lineups.isEmpty {
                ContentUnavailableView {
                    Label("No Lineups", systemImage: "rectangle.stack")
                } description: {
                    Text(
                        "Build a schedule, deck, or rotation in Tesserae's web interface, then refresh."
                    )
                } actions: {
                    Button("Refresh") {
                        Task { await model.refreshLineups() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .refreshable {
            await model.refreshLineups()
        }
        .task(id: shouldAutoRefresh) {
            guard shouldAutoRefresh else { return }

            await model.refreshLineups(
                showErrors: false,
                saveSnapshot: false
            )
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                await model.refreshLineups(
                    showErrors: false,
                    saveSnapshot: false
                )
            }
        }
        .tesseraeScreenBackground()
    }
}

private struct LineupCard: View {
    @Environment(AppModel.self) private var model

    let lineup: Lineup

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: lineup.intent?.symbolName ?? "rectangle.stack")
                .font(.title3.weight(.semibold))
                .foregroundStyle(TesseraeTheme.accent)
                .frame(width: 40, height: 40)
                .background(
                    TesseraeTheme.accent.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(lineup.name)
                        .font(.headline)
                        .lineLimit(1)

                    LineupStatusBadge(enabled: lineup.enabled)
                }

                Text(lineupSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(currentSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(lineup.name), \(lineup.enabled ? "enabled" : "disabled"), \(lineupSummary), \(currentSummary)"
        )
        .accessibilityHint("Opens Lineup details and controls.")
    }

    private var lineupSummary: String {
        let intent = lineup.intent?.displayName ?? String(localized: "Advanced")
        let displayCount = lineup.deviceIDs.count
        let displayText = displayCount == 1
            ? String(localized: "1 display")
            : String(localized: "\(displayCount) displays")
        let pageCount = lineup.dashboards.count
        let pageText = pageCount == 1
            ? String(localized: "1 dashboard")
            : String(localized: "\(pageCount) dashboards")
        return "\(intent) · \(displayText) · \(pageText)"
    }

    private var currentSummary: String {
        let currentPageIDs = Set(lineup.current.map(\.pageID))
        if currentPageIDs.isEmpty {
            return String(localized: "No current dashboard")
        }
        if currentPageIDs.count == 1,
           let pageID = currentPageIDs.first
        {
            let pageName = lineup.dashboards.first {
                $0.pageID == pageID
            }?.name ?? pageID
            return String(localized: "Showing \(pageName)")
        }
        return String(
            localized: "\(currentPageIDs.count) dashboards currently showing"
        )
    }
}

private struct LineupDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var didLoadInitialTargets = false

    let lineupID: String

    private var lineup: Lineup? {
        model.lineups.first { $0.id == lineupID }
    }

    var body: some View {
        Group {
            if let lineup {
                ScrollView {
                    VStack(spacing: 14) {
                        overviewCard(lineup)

                        if !lineup.nativeEditable {
                            webManagedCard(lineup)
                        }

                        if model.supportsLineupControl {
                            controlsCard(lineup)
                            targetsCard(lineup)
                        } else {
                            readOnlyCard
                        }

                        dashboardsCard(lineup)
                        behaviorCard(lineup)
                    }
                    .padding(16)
                }
                .refreshable {
                    await model.refreshLineups()
                }
                .task(id: lineup.deviceIDs) {
                    reconcileTargets(lineup.deviceIDs)
                }
            } else {
                ContentUnavailableView {
                    Label("Lineup Unavailable", systemImage: "rectangle.slash")
                } description: {
                    Text("This Lineup is no longer returned by the server.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refreshLineups() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(lineup?.name ?? String(localized: "Lineup"))
        .navigationBarTitleDisplayMode(.inline)
        .tesseraeScreenBackground()
    }

    private func overviewCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: lineup.intent?.symbolName ?? "rectangle.stack")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.accent)
                    .frame(width: 44, height: 44)
                    .background(
                        TesseraeTheme.accent.opacity(0.11),
                        in: RoundedRectangle(
                            cornerRadius: 13,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(lineup.name)
                            .font(.title3.weight(.semibold))
                        LineupStatusBadge(enabled: lineup.enabled)
                    }

                    Text(lineup.intent?.displayName ?? "Advanced Lineup")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Divider()

            LabeledContent("Bound displays") {
                Text(displayCountText(lineup.deviceIDs.count))
            }
            LabeledContent("Dashboards") {
                Text("\(lineup.dashboards.count)")
            }
            if let nextAdvanceEpoch = lineup.nextAdvanceEpoch {
                LabeledContent("Next advance") {
                    Text(
                        Date(timeIntervalSince1970: TimeInterval(nextAdvanceEpoch)),
                        format: .dateTime.month(.abbreviated).day().hour().minute()
                    )
                }
            }

            if let destination = webURL(for: lineup) {
                Button {
                    openURL(destination)
                } label: {
                    Label("Open in Tesserae", systemImage: "safari")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("lineup-open-web")
            }
        }
        .tesseraeCard()
    }

    private func webManagedCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Definition managed on the web", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(TesseraeTheme.ochre)

            Text(
                lineup.requiresWebReason
                    ?? String(localized: "This Lineup uses advanced settings that the app does not edit.")
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            Text("You can still enable, disable, and control it here.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }

    private func controlsCard(_ lineup: Lineup) -> some View {
        let isOperating = model.isOperatingOnLineup(lineup.id)
        let canMove = lineup.dashboards.count > 1
            && !selectedDeviceIDs.isEmpty
            && !isOperating

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Controls")
                    .font(.headline)

                Spacer()

                Button {
                    Task {
                        await model.setLineupEnabled(
                            lineup,
                            enabled: !lineup.enabled
                        )
                    }
                } label: {
                    Label(
                        lineup.enabled ? "Disable" : "Enable",
                        systemImage: lineup.enabled ? "pause.circle" : "play.circle"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(isOperating)
                .accessibilityIdentifier("lineup-enabled-control")
            }

            HStack(spacing: 10) {
                Button {
                    runPaintAction(.previous, lineup: lineup)
                } label: {
                    Label("Previous", systemImage: "backward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canMove)
                .accessibilityIdentifier("lineup-previous")

                Button {
                    runPaintAction(.next, lineup: lineup)
                } label: {
                    Label("Next", systemImage: "forward.end.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canMove)
                .accessibilityIdentifier("lineup-next")
            }

            if isOperating {
                Label("Updating Lineup…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if selectedDeviceIDs.isEmpty {
                Text("Select at least one bound display to use paint controls.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Paint actions bypass quiet hours and appear in Activity.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tesseraeCard()
    }

    private func targetsCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Target Displays")
                    .font(.headline)

                Spacer()

                if !lineup.deviceIDs.isEmpty {
                    Button("Select All") {
                        selectedDeviceIDs = Set(lineup.deviceIDs)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if lineup.deviceIDs.isEmpty {
                Text("This Lineup has no bound displays.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(lineup.deviceIDs, id: \.self) { deviceID in
                    Button {
                        if selectedDeviceIDs.contains(deviceID) {
                            selectedDeviceIDs.remove(deviceID)
                        } else {
                            selectedDeviceIDs.insert(deviceID)
                        }
                    } label: {
                        TesseraeDisplaySelectionRow(
                            name: displayName(deviceID),
                            resolution: displayResolution(deviceID),
                            isSelected: selectedDeviceIDs.contains(deviceID)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lineup-target-\(deviceID)")
                }
            }
        }
        .tesseraeCard()
    }

    private var readOnlyCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Read only", systemImage: "lock")
                .font(.headline)
            Text(
                "This server exposes Lineups but does not advertise app controls."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }

    private func dashboardsCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Dashboards")
                .font(.headline)
                .padding(.bottom, 5)

            ForEach(Array(lineup.dashboards.enumerated()), id: \.element.pageID) {
                index, dashboard in
                if index > 0 {
                    Divider()
                }
                dashboardRow(dashboard, lineup: lineup, position: index + 1)
            }
        }
        .tesseraeCard()
    }

    private func dashboardRow(
        _ dashboard: LineupDashboard,
        lineup: Lineup,
        position: Int
    ) -> some View {
        let currentDeviceIDs = lineup.current.compactMap {
            $0.pageID == dashboard.pageID ? $0.deviceID : nil
        }
        let isOperating = model.isOperatingOnLineup(lineup.id)

        return HStack(alignment: .center, spacing: 10) {
            Text("\(position)")
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Color.primary.opacity(0.055),
                    in: Circle()
                )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(dashboard.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(dashboard.missing ? .secondary : .primary)

                    if dashboard.missing {
                        Text("Missing")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(TesseraeTheme.terracotta)
                    }
                }

                Text(dashboardMetadata(dashboard))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !currentDeviceIDs.isEmpty {
                    Label(
                        "Showing on \(displayNames(currentDeviceIDs))",
                        systemImage: "display"
                    )
                    .font(.caption)
                    .foregroundStyle(TesseraeTheme.accent)
                }
            }

            Spacer(minLength: 4)

            if model.supportsLineupControl {
                Button {
                    runPaintAction(
                        .play,
                        lineup: lineup,
                        pageID: dashboard.pageID
                    )
                } label: {
                    Image(systemName: "play.fill")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .disabled(
                    dashboard.missing
                        || selectedDeviceIDs.isEmpty
                        || isOperating
                )
                .accessibilityLabel("Play \(dashboard.name)")
                .accessibilityIdentifier("lineup-play-\(dashboard.pageID)")
            }
        }
        .padding(.vertical, 9)
    }

    private func behaviorCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Behavior")
                .font(.headline)

            LabeledContent("Advance") {
                Text(lineup.advance.displayName)
            }

            if let trigger = lineup.trigger {
                LabeledContent("Trigger") {
                    Text(trigger.displayName)
                }
            }
            if let mode = lineup.mode {
                LabeledContent("Mode") {
                    Text(mode.displayName)
                }
            }
            if let interval = lineup.intervalMinutes {
                valueRow("Interval", minutesText(interval))
            }
            if let firesAt = lineup.firesAt {
                valueRow("Fires at", firesAt)
            }
            if let anchor = lineup.anchor {
                valueRow("Anchor", anchor)
            }
            if let days = lineup.daysOfWeek {
                valueRow("Days", daysText(days))
            }
            if let endAt = lineup.endAt {
                valueRow("Ends at", endAt)
            }
            if let windowStart = lineup.windowStart,
               let windowEnd = lineup.windowEnd
            {
                valueRow("Window", "\(windowStart)–\(windowEnd)")
            } else if let windowStart = lineup.windowStart {
                valueRow("Window starts", windowStart)
            } else if let windowEnd = lineup.windowEnd {
                valueRow("Window ends", windowEnd)
            }
            if let refresh = lineup.refreshIntervalMinutes {
                valueRow(
                    "Refresh",
                    refresh == 0 ? String(localized: "Off") : minutesText(refresh)
                )
            }
            if let home = lineup.homePageID {
                valueRow("Home dashboard", pageName(home, in: lineup))
            }
            if let timeout = lineup.homeTimeoutMinutes {
                valueRow(
                    "Return home",
                    timeout == 0 ? String(localized: "Off") : minutesText(timeout)
                )
            }
            if let entry = lineup.entryPageID {
                valueRow("Entry dashboard", pageName(entry, in: lineup))
            }
            if let fallback = lineup.fallbackPageID {
                valueRow("Fallback dashboard", pageName(fallback, in: lineup))
            }
            if let priority = lineup.priority {
                valueRow("Priority", "\(priority)")
            }
            if let minimumHold = lineup.minHoldMinutes {
                valueRow("Minimum hold", minutesText(minimumHold))
            }
            if let smartSync = lineup.smartSync {
                valueRow("Smart sync", smartSync ? "On" : "Off")
            }
            if lineup.smartSync == true,
               let leadSeconds = lineup.smartSyncLeadSeconds
            {
                valueRow("Smart sync lead", "\(leadSeconds) sec")
            }
        }
        .tesseraeCard()
    }

    private func valueRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private func runPaintAction(
        _ action: LineupPaintAction,
        lineup: Lineup,
        pageID: String? = nil
    ) {
        Task {
            await model.controlLineup(
                lineup,
                action: action,
                pageID: pageID,
                deviceIDs: Array(selectedDeviceIDs).sorted()
            )
        }
    }

    private func reconcileTargets(_ boundDeviceIDs: [String]) {
        let bound = Set(boundDeviceIDs)
        if !didLoadInitialTargets {
            didLoadInitialTargets = true
            selectedDeviceIDs = bound
            return
        }
        selectedDeviceIDs.formIntersection(bound)
    }

    private func displayName(_ deviceID: String) -> String {
        model.displays.first { $0.id == deviceID }?.name ?? deviceID
    }

    private func displayResolution(_ deviceID: String) -> String {
        guard let display = model.displays.first(where: { $0.id == deviceID }) else {
            return String(localized: "Unavailable")
        }
        return "\(display.panel.width)×\(display.panel.height)"
    }

    private func displayNames(_ deviceIDs: [String]) -> String {
        deviceIDs.map(displayName).joined(separator: ", ")
    }

    private func displayCountText(_ count: Int) -> String {
        count == 1
            ? String(localized: "1 display")
            : String(localized: "\(count) displays")
    }

    private func dashboardMetadata(_ dashboard: LineupDashboard) -> String {
        var parts = [minutesText(dashboard.dwellMinutes)]
        if let refresh = dashboard.refreshIntervalMinutes {
            parts.append(
                refresh == 0
                    ? String(localized: "refresh off")
                    : String(localized: "refresh \(minutesText(refresh))")
            )
        }
        if let links = dashboard.links, !links.isEmpty {
            parts.append(
                links.count == 1
                    ? String(localized: "1 link")
                    : String(localized: "\(links.count) links")
            )
        }
        if let conditions = dashboard.conditions, !conditions.isEmpty {
            parts.append(
                conditions.count == 1
                    ? String(localized: "1 condition")
                    : String(localized: "\(conditions.count) conditions")
            )
        }
        return parts.joined(separator: " · ")
    }

    private func minutesText(_ minutes: Int) -> String {
        minutes == 1
            ? String(localized: "1 min")
            : String(localized: "\(minutes) min")
    }

    private func daysText(_ days: [Int]) -> String {
        let normalized = Array(Set(days)).sorted()
        if normalized == Array(0...6) {
            return String(localized: "Every day")
        }
        if normalized == Array(0...4) {
            return String(localized: "Weekdays")
        }
        let names = [
            String(localized: "Mon"),
            String(localized: "Tue"),
            String(localized: "Wed"),
            String(localized: "Thu"),
            String(localized: "Fri"),
            String(localized: "Sat"),
            String(localized: "Sun"),
        ]
        return normalized.compactMap { names.indices.contains($0) ? names[$0] : nil }
            .joined(separator: ", ")
    }

    private func pageName(_ pageID: String, in lineup: Lineup) -> String {
        lineup.dashboards.first { $0.pageID == pageID }?.name ?? pageID
    }

    private func webURL(for lineup: Lineup) -> URL? {
        guard let baseURL = model.activeInstance?.baseURL else { return nil }
        return URL(string: lineup.webURL, relativeTo: baseURL)?.absoluteURL
    }
}

private struct LineupStatusBadge: View {
    let enabled: Bool

    var body: some View {
        Text(enabled ? "Enabled" : "Disabled")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(enabled ? TesseraeTheme.accent : .secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                (enabled ? TesseraeTheme.accent : Color.secondary).opacity(0.11),
                in: Capsule()
            )
    }
}

private extension LineupIntent {
    var displayName: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .interval: String(localized: "Interval")
        case .cycle: String(localized: "Cycle")
        case .manual: String(localized: "Manual")
        }
    }

    var symbolName: String {
        switch self {
        case .daily: "calendar"
        case .interval: "timer"
        case .cycle: "arrow.triangle.2.circlepath"
        case .manual: "hand.tap"
        }
    }
}

private extension LineupAdvance {
    var displayName: String {
        switch self {
        case .manual: String(localized: "Manual")
        case .timer: String(localized: "Timer")
        case .both: String(localized: "Manual and timer")
        }
    }
}

private extension LineupTrigger {
    var displayName: String {
        switch self {
        case .cycle: String(localized: "Cycle")
        case .interval: String(localized: "Interval")
        case .daily: String(localized: "Daily")
        }
    }
}

private extension LineupMode {
    var displayName: String {
        switch self {
        case .scheduled: String(localized: "Scheduled")
        case .priority: String(localized: "Priority")
        }
    }
}
