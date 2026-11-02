import SwiftUI
import TesseraeKit

struct LineupsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var query = ""
    @State private var collapsedSectionIDs: Set<String> = []
    @State private var creatingLineup = false
    @State private var permissionAlertPresented = false

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    private var searchQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var sections: [LineupListSection] {
        let matchingLineups = model.lineups.filter {
            searchQuery.isEmpty || $0.name.localizedStandardContains(searchQuery)
                || displayDeviceIDs(for: $0).contains { id in
                    model.displays.first { $0.id == id }?.name.localizedStandardContains(searchQuery) == true
                }
        }
        let knownDisplayIDs = Set(model.displays.map(\.id))
        let groupedLineups = Dictionary(grouping: matchingLineups) {
            lineupDisplayGrouping(
                deviceIDs: displayDeviceIDs(for: $0),
                knownDisplayIDs: knownDisplayIDs
            )
        }
        var result: [LineupListSection] = []

        for display in model.sortedDisplays {
            let lineups = groupedLineups[.display(display.id)] ?? []
            if !lineups.isEmpty {
                result.append(
                    LineupListSection(
                        id: "display-\(display.id)",
                        kind: .display(display),
                        lineups: lineups
                    )
                )
            }
        }

        let shared = groupedLineups[.shared] ?? []
        if !shared.isEmpty {
            result.append(
                LineupListSection(
                    id: "shared",
                    kind: .shared,
                    lineups: shared
                )
            )
        }

        let unassigned = groupedLineups[.unassigned] ?? []
        if !unassigned.isEmpty {
            result.append(
                LineupListSection(
                    id: "unassigned",
                    kind: .unassigned,
                    lineups: unassigned
                )
            )
        }

        let unavailable = groupedLineups[.unavailable] ?? []
        if !unavailable.isEmpty {
            result.append(
                LineupListSection(
                    id: "unavailable",
                    kind: .unavailable,
                    lineups: unavailable
                )
            )
        }

        return result
    }

    private func displayDeviceIDs(for lineup: Lineup) -> [String] {
        resolvedLineupDeviceIDs(
            explicitDeviceIDs: lineup.deviceIDs,
            serverResolvedDeviceIDs: lineup.resolvedDeviceIDs
        )
    }

    var body: some View {
        let listSections = sections

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(listSections) { section in
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader(section)

                        if !collapsedSectionIDs.contains(section.id) || !searchQuery.isEmpty {
                            LazyVStack(spacing: 0) {
                                ForEach(
                                    Array(section.lineups.enumerated()),
                                    id: \.element.id
                                ) { index, lineup in
                                    VStack(spacing: 0) {
                                        if index > 0 {
                                            Divider()
                                        }

                                        NavigationLink(value: LineupRoute.lineup(id: lineup.id, displayID: section.displayID)) {
                                            LineupListRow(
                                                lineup: lineup,
                                                plans: plans(for: lineup)
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityIdentifier(
                                            "lineup-card-\(lineup.id)"
                                        )
                                    }
                                }
                            }
                            .tesseraeCard()
                        }
                    }
                }
            }
            .padding(16)
        }
        .overlay {
            if model.lineups.isEmpty
                && (model.isRefreshingLineups || model.isRefreshing)
            {
                ProgressView("Loading Lineups…")
            } else if model.lineups.isEmpty {
                ContentUnavailableView {
                    Label("No Lineups", systemImage: "rectangle.stack")
                } description: {
                    if model.supportsLineupAuthoring {
                        Text("Create a Lineup to schedule or control your Dashboards.")
                    } else {
                        Text(
                            "Build a schedule, deck, or rotation in Tesserae's web interface, then refresh."
                        )
                    }
                } actions: {
                    if model.supportsLineupAuthoring {
                        Button("Create Lineup") {
                            beginCreatingLineup()
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(TesseraeTheme.accentFill)
                        .foregroundStyle(.white)
                    }
                    Button("Refresh") {
                        Task { await model.refreshLineups() }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search displays and Lineups")
        .overlay {
            if !model.lineups.isEmpty, !searchQuery.isEmpty, listSections.isEmpty {
                ContentUnavailableView.search(text: searchQuery)
                    .accessibilityIdentifier("lineup-search-empty")
            }
        }
        .refreshable {
            await model.refreshLineups()
            await refreshPlans()
        }
        .task(id: shouldAutoRefresh) {
            guard shouldAutoRefresh else { return }

            await model.refreshLineups(
                showErrors: false,
                saveSnapshot: false
            )
            await refreshPlans()
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
                guard !Task.isCancelled else { return }
                await refreshPlans()
            }
        }
        .navigationTitle("Lineups")
        .toolbar {
            if model.supportsLineupAuthoring {
                TesseraeToolbarActions {
                    Button("Create Lineup", systemImage: "plus") {
                        beginCreatingLineup()
                    }
                    .accessibilityIdentifier("lineup-create")
                }
            }
        }
        .sheet(isPresented: $creatingLineup) {
            LineupCreateFlow { _ in }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert("Permission Required", isPresented: $permissionAlertPresented) {
            Button("Open Tesserae") {
                if let url = lineupAuthoringWebURL(model: model) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enable Create and edit Lineups for this device in Tesserae Settings → Companion. You do not need to pair again."
            )
        }
        .tesseraeScreenBackground()
    }

    private func beginCreatingLineup() {
        if model.lineupAuthoringPermission == .denied {
            Task {
                await model.refreshLineupAuthoringPermission()
                if model.lineupAuthoringPermission == .denied {
                    permissionAlertPresented = true
                } else {
                    creatingLineup = true
                }
            }
        } else {
            creatingLineup = true
        }
    }

    private func plans(for lineup: Lineup) -> [DisplayPlanProjection] {
        displayPlanProjections(
            deviceIDs: displayDeviceIDs(for: lineup), displays: model.displays,
            supported: model.supportsDeviceTimeline, responses: model.deviceUpcomingResponses,
            refreshing: model.loadingDeviceTimelineIDs, errors: model.deviceTimelineErrors,
            lineupID: lineup.id
        )
    }

    private func refreshPlans() async {
        let known = Set(model.displays.map(\.id))
        let ids = Set(model.lineups.flatMap { displayDeviceIDs(for: $0) }).intersection(known)
        for id in ids.sorted() {
            guard !Task.isCancelled else { return }
            await model.refreshDeviceUpcoming(displayID: id)
        }
    }

    private func sectionHeader(_ section: LineupListSection) -> some View {
        let isCollapsed = collapsedSectionIDs.contains(section.id) && searchQuery.isEmpty
        return HStack(spacing: 10) {
            if let id = section.displayID {
                NavigationLink(value: LineupRoute.display(id: id)) {
                    HStack(spacing: 10) {
                        sectionIcon(section)
                        Text(section.title).font(.headline)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("lineup-display-\(id)")
            } else {
                sectionIcon(section)
                Text(section.title).font(.headline)
            }
            Spacer(minLength: 4)
            Text(section.lineups.count, format: .number)
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Button {
                if !collapsedSectionIDs.insert(section.id).inserted {
                    collapsedSectionIDs.remove(section.id)
                }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.caption.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "Expand or collapse \(section.title)"))
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .accessibilityIdentifier("lineup-group-\(section.id)")
        }
    }

    @ViewBuilder
    private func sectionIcon(_ section: LineupListSection) -> some View {
        switch section.kind {
        case let .display(display):
            PhosphorIcon(
                name: display.canonicalIconName,
                size: 18,
                color: TesseraeTheme.accent,
                fallbackSystemName: display.panel.height > display.panel.width
                    ? "rectangle.portrait.inset.filled"
                    : "rectangle.inset.filled"
            )
        case .shared:
            Image(systemName: "rectangle.3.group")
                .font(.subheadline.weight(.semibold))
        case .unassigned:
            Image(systemName: "rectangle.badge.plus")
                .font(.subheadline.weight(.semibold))
        case .unavailable:
            Image(systemName: "rectangle.stack.badge.questionmark")
                .font(.subheadline.weight(.semibold))
        }
    }
}

enum LineupDisplayGrouping: Hashable {
    case display(String)
    case shared
    case unassigned
    case unavailable
}

func lineupDisplayGrouping(
    deviceIDs: [String],
    knownDisplayIDs: Set<String>
) -> LineupDisplayGrouping {
    if deviceIDs.isEmpty {
        return .unassigned
    }
    if deviceIDs.count > 1 {
        return .shared
    }
    guard let deviceID = deviceIDs.first,
          knownDisplayIDs.contains(deviceID)
    else {
        return .unavailable
    }
    return .display(deviceID)
}

func resolvedLineupDeviceIDs(
    explicitDeviceIDs: [String],
    serverResolvedDeviceIDs: [String]?
) -> [String] {
    let candidates = serverResolvedDeviceIDs ?? explicitDeviceIDs
    var seen: Set<String> = []
    return candidates.filter { seen.insert($0).inserted }
}

private struct LineupListSection: Identifiable {
    enum Kind {
        case display(DisplaySummary)
        case shared
        case unassigned
        case unavailable
    }

    let id: String
    let kind: Kind
    let lineups: [Lineup]

    var title: String {
        switch kind {
        case let .display(display): display.name
        case .shared: String(localized: "Shared Displays")
        case .unassigned: String(localized: "Unassigned Lineups")
        case .unavailable: String(localized: "Unavailable Displays")
        }
    }

    var displayID: String? {
        if case let .display(display) = kind { return display.id }
        return nil
    }

    var subtitle: String? {
        switch kind {
        case .display:
            nil
        case .shared:
            String(localized: "Controls more than one display")
        case .unassigned:
            String(localized: "Choose a display in Tesserae")
        case .unavailable:
            String(localized: "Assigned display is not available")
        }
    }
}

struct LineupListRow: View {
    let lineup: Lineup
    let plans: [DisplayPlanProjection]

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        Text(lineup.name).font(.headline)
                        Spacer(minLength: 8)
                        enabledLabel
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lineup.name).font(.headline)
                        enabledLabel
                    }
                }
                Text([lineupScheduleSummary(lineup), lineupDaysSummary(lineup.daysOfWeek)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                CompactLineupPlanSummary(plans: plans)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens Lineup details and controls.")
    }

    private var enabledLabel: some View {
        Text(lineup.enabled ? "Enabled" : "Disabled")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(lineup.enabled ? TesseraeTheme.success : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct CompactLineupPlanSummary: View {
    let plans: [DisplayPlanProjection]

    private var earliest: PlannedDisplayEvent? {
        plans.compactMap(\.next).min { $0.event.scheduledAt < $1.event.scheduledAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let next = earliest, let plan = plans.first(where: { $0.id == next.displayID }) {
                Text(String(localized: "Next planned update") + " · " + (plans.count > 1 ? plan.displayName + " · " : "") + plannedEventTime(next) + " · " + plannedCertaintyTitle(next.event.certainty))
                    .foregroundStyle(TesseraeTheme.info)
                if plan.error != nil { Text("Previous projection · Refresh failed").foregroundStyle(.secondary) }
                if plans.count > 1 {
                    Text(String(localized: "Other targets: \(plans.count - 1). Open details for each display."))
                        .foregroundStyle(.secondary)
                }
                let missing = plans.filter { $0.availability != .available }.count
                if missing > 0 {
                    Text(String(localized: "\(missing) targets lack a current projection")).foregroundStyle(.secondary)
                }
            } else if let plan = plans.first {
                Text(plan.status).foregroundStyle(.secondary)
                if plans.count > 1 { Text(String(localized: "\(plans.count) targets · Open details for each display.")).foregroundStyle(.secondary) }
            } else {
                Text("No display").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct LineupDashboardPlayContext: Identifiable {
    let lineupID: String
    let dashboard: LineupDashboard

    var id: String {
        "\(lineupID)|\(dashboard.pageID)"
    }
}

struct LineupDetailView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var positionBadgeSize = 24

    private var detailLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
            : AnyLayout(HStackLayout(spacing: 10))
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var planNow = Date()
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var didLoadInitialTargets = false
    @State private var detailsExpanded = false
    @State private var targetsPresented = false
    @State private var dashboardToPreview: LineupDashboardPlayContext?
    @State private var pendingEnabled: Bool?
    @State private var isUpdatingEnabled = false
    @State private var editingLineup = false
    @State private var authoringPermissionAlertPresented = false

    let lineupID: String
    var originatingDisplayID: String? = nil

    private var lineup: Lineup? {
        model.lineups.first { $0.id == lineupID }
    }

    var body: some View {
        Group {
            if let lineup {
                ScrollView {
                    VStack(spacing: 14) {
                        summaryRow(lineup)
                        scheduleCard(lineup)
                        dashboardsCard(lineup)
                        displayLinksCard(lineup)

                        if !lineup.nativeEditable {
                            webManagedBanner(lineup)
                        }

                        if !model.supportsLineupControl {
                            readOnlyBanner
                        }

                        secondaryDetailsCard(lineup)
                    }
                    .padding(16)
                }
                .refreshable {
                    await refreshDetail()
                }
                .task(id: displayDeviceIDs(for: lineup)) {
                    reconcileTargets(displayDeviceIDs(for: lineup))
                }
                .task(id: "\(selectedDeviceIDs.sorted())|\(model.connectionRevision)") {
                    await refreshDetailPlans()
                    while !Task.isCancelled {
                        guard let current = self.lineup, model.supportsDeviceTimeline else { return }
                        let plans = detailPlans(current)
                        let deadlines = plans.flatMap { [$0.next?.event.scheduledAt, $0.response?.throughAt].compactMap { $0 } }
                        let delay = deadlines.map { $0.timeIntervalSinceNow + 1 }.filter { $0 > 0 }.min() ?? 30
                        do { try await Task.sleep(for: .seconds(min(delay, 60))) } catch { return }
                        guard !Task.isCancelled else { return }
                        planNow = Date()
                        await refreshDetailPlans()
                    }
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
                    .tint(TesseraeTheme.accentFill)
                    .foregroundStyle(.white)
                }
            }
        }
        .navigationTitle(lineup?.name ?? String(localized: "Lineup"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TesseraeToolbarActions {
                if let lineup,
                   lineup.nativeEditable,
                   model.supportsLineupAuthoring
                {
                    Button("Edit", systemImage: "pencil") {
                        beginEditingLineup()
                    }
                    .accessibilityIdentifier("lineup-edit")
                }
                Menu {
                    if let lineup,
                       let destination = webURL(for: lineup)
                    {
                        Button("Open in Tesserae", systemImage: "safari") {
                            openURL(destination)
                        }
                    }

                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await refreshDetail() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .accessibilityIdentifier("lineup-more-menu")
            }
        }
        .sheet(isPresented: $editingLineup) {
            LineupEditFlow(lineupID: lineupID) { _ in }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .alert(
            "Permission Required",
            isPresented: $authoringPermissionAlertPresented
        ) {
            Button("Open Tesserae") {
                if let url = lineupAuthoringWebURL(model: model) {
                    openURL(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Enable Create and edit Lineups for this device in Tesserae Settings → Companion. You do not need to pair again."
            )
        }
        .task(id: model.supportsLineupAuthoring) {
            guard model.supportsLineupAuthoring else { return }
            await model.refreshLineupAuthoringPermission()
        }
        .sheet(isPresented: $targetsPresented) {
            if let lineup {
                LineupTargetSelectionSheet(
                    deviceIDs: displayDeviceIDs(for: lineup),
                    displays: model.displays,
                    selection: $selectedDeviceIDs
                )
            }
        }
        .sheet(item: $dashboardToPreview) { context in
            if let lineup = model.lineups.first(where: {
                $0.id == context.lineupID
            }) {
                let availableTargetIDs = Set(displayDeviceIDs(for: lineup)).intersection(Set(model.displays.map(\.id)))
                let initialTargetIDs = presentationDeviceIDs(for: lineup)
                    .intersection(availableTargetIDs)
                let displays = model.sortedDisplays.filter {
                    availableTargetIDs.contains($0.id)
                }

                DashboardPreviewActionSheet(
                    dashboardID: context.dashboard.pageID,
                    dashboardName: context.dashboard.name,
                    previewDeviceID: initialTargetIDs.intersection(Set(displays.map(\.id))).sorted().first,
                    displays: displays,
                    initialDeviceIDs: initialTargetIDs,
                    showsDisplayPicker: displays.count != 1,
                    action: .playLineup(
                        lineupID: context.lineupID,
                        pageID: context.dashboard.pageID
                    )
                )
            }
        }
        .tesseraeScreenBackground()
    }

    private func detailPlans(_ lineup: Lineup) -> [DisplayPlanProjection] {
        displayPlanProjections(
            deviceIDs: presentationDeviceIDs(for: lineup).sorted(), displays: model.displays,
            supported: model.supportsDeviceTimeline, responses: model.deviceUpcomingResponses,
            refreshing: model.loadingDeviceTimelineIDs, errors: model.deviceTimelineErrors,
            lineupID: lineup.id, now: planNow
        )
    }

    private func controlTargetIDs(for lineup: Lineup) -> Set<String> {
        presentationDeviceIDs(for: lineup).intersection(Set(model.displays.map(\.id)))
    }

    private func thumbnailDisplay(for lineup: Lineup) -> DisplaySummary? {
        let selected = controlTargetIDs(for: lineup)
        guard selected.count == 1, let id = selected.first else { return nil }
        return model.displays.first { $0.id == id }
    }

    private func refreshDetail() async {
        await model.refreshLineups()
        guard !Task.isCancelled else { return }
        await refreshDetailPlans()
    }

    private func refreshDetailPlans() async {
        planNow = Date()
        guard let lineup else { return }
        for id in controlTargetIDs(for: lineup).sorted() {
            guard !Task.isCancelled else { return }
            await model.refreshDeviceUpcoming(displayID: id)
        }
    }

    private func scheduleCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(lineupScheduleSummary(lineup), systemImage: "clock")
                    .font(.headline)
                Spacer(minLength: 4)
                if let end = lineup.endAt { Text(end).font(.caption).foregroundStyle(.secondary) }
            }
            if let days = lineup.daysOfWeek {
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { day in
                        Text(weekdayName(day))
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 30)
                            .foregroundStyle(days.contains(day) ? TesseraeTheme.accent : Color.secondary)
                            .background(days.contains(day) ? TesseraeTheme.accent.opacity(0.1) : Color.secondary.opacity(0.05), in: Capsule())
                            .accessibilityLabel(weekdayName(day) + " · " + (days.contains(day) ? String(localized: "Enabled") : String(localized: "Disabled")))
                    }
                }
                .accessibilityIdentifier("lineup-weekdays")
            }
            Text([lineupDaysSummary(lineup.daysOfWeek), model.activeInstance?.timezone].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(detailPlans(lineup)) { plan in
                DisplayPlanSummary(plan: plan, showsDisplayName: true)
            }
            if presentationDeviceIDs(for: lineup).isEmpty {
                Text("Select a target").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tesseraeCard()
    }

    private func weekdayName(_ day: Int) -> String {
        [String(localized: "Mon"), String(localized: "Tue"), String(localized: "Wed"),
         String(localized: "Thu"), String(localized: "Fri"), String(localized: "Sat"), String(localized: "Sun")][day]
    }

    private func stepPlanTimes(_ dashboard: LineupDashboard, lineup: Lineup) -> some View {
        let plans = detailPlans(lineup)
        return VStack(alignment: .leading, spacing: 3) {
            ForEach(plans) { plan in
                if let event = plan.events.first(where: { $0.event.dashboardID == dashboard.pageID && $0.event.scheduledAt > plan.now }), plan.availability == .available {
                    Text((plans.count > 1 ? plan.displayName + " · " : "") + plannedEventTime(event) + " · " + plannedCertaintyTitle(event.event.certainty))
                        .font(.caption2).foregroundStyle(TesseraeTheme.info)
                    if plan.error != nil { Text("Previous projection · Refresh failed").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private func displayLinksCard(_ lineup: Lineup) -> some View {
        let ids = displayDeviceIDs(for: lineup)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Display previews & updates").font(.headline)
            ForEach(ids, id: \.self) { id in
                if model.displays.contains(where: { $0.id == id }) {
                    NavigationLink(value: LineupRoute.display(id: id)) {
                        HStack(spacing: 10) {
                            Image(systemName: "display")
                            Text(displayName(id)).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("lineup-detail-display-\(id)")
                } else {
                    Text(displayName(id) + " · " + String(localized: "Assigned display is not available"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if ids.isEmpty { Text("No display").foregroundStyle(.secondary) }
        }
        .tesseraeCard()
    }

    private func summaryRow(_ lineup: Lineup) -> some View {
        return HStack(spacing: 10) {
            Label(
                lineup.intent?.displayName ?? "Advanced",
                systemImage: lineup.intent?.symbolName ?? "rectangle.stack"
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(TesseraeTheme.accent)

            Spacer(minLength: 6)

            if model.supportsLineupControl {
                lineupEnabledControl(lineup)
            } else {
                Text(lineup.enabled ? "Enabled" : "Disabled")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 2)
    }

    private func lineupEnabledControl(_ lineup: Lineup) -> some View {
        let displayedEnabled = pendingEnabled ?? lineup.enabled

        return Toggle("Enabled", isOn: Binding(
            get: { pendingEnabled ?? lineup.enabled },
            set: { enabled in
                pendingEnabled = enabled
                isUpdatingEnabled = true
                Task {
                    let succeeded = await model.setLineupEnabled(lineup, enabled: enabled)
                    if !succeeded { pendingEnabled = nil }
                    isUpdatingEnabled = false
                }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .tint(TesseraeTheme.accentFill)
        .frame(minWidth: 51, minHeight: 44)
        .disabled(isUpdatingEnabled)
        .accessibilityIdentifier(
            displayedEnabled ? "lineup-enabled-on" : "lineup-enabled-off"
        )
        .onChange(of: lineup.enabled) { _, enabled in
            if pendingEnabled == enabled {
                pendingEnabled = nil
            }
        }
    }

    private func dashboardsCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            dashboardsHeader(lineup)
                .padding(.bottom, 7)

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

    private func dashboardsHeader(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Steps").font(.headline)
                Spacer()
                Text(String(localized: "\(lineup.dashboards.count) steps"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(LineupNavigationState(targetIDs: presentationDeviceIDs(for: lineup), current: lineup.current).title(dashboards: lineup.dashboards))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("lineup-playback-status")
            Text("Schedule state does not confirm the screen currently displayed.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func dashboardRow(
        _ dashboard: LineupDashboard,
        lineup: Lineup,
        position: Int
    ) -> some View {
        let selectedTargets = controlTargetIDs(for: lineup)
        let navigation = LineupStepNavigation(pageID: dashboard.pageID, targetIDs: selectedTargets, current: lineup.current)
        let isCurrent = !navigation.matchingTargetIDs.isEmpty
        let isOperating = model.isOperatingOnLineup(lineup.id)

        return HStack(alignment: .center, spacing: 11) {
            Button {
                dashboardToPreview = LineupDashboardPlayContext(
                    lineupID: lineup.id,
                    dashboard: dashboard
                )
            } label: {
                HStack(alignment: .center, spacing: 11) {
                    Text("\(position)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(
                            isCurrent ? Color.white : Color.secondary
                        )
                        .frame(width: positionBadgeSize, height: positionBadgeSize)
                        .background(
                            isCurrent
                                ? TesseraeTheme.accentFill
                                : Color.primary.opacity(0.055),
                            in: Circle()
                        )

                    LineupStepThumbnail(dashboard: dashboard, display: thumbnailDisplay(for: lineup))

                    VStack(alignment: .leading, spacing: 4) {
                        if isCurrent {
                            Text(navigation.allSelectedTargetsMatch ? String(localized: "Schedule step") : String(localized: "Schedule step for \(displayNames(navigation.matchingTargetIDs.sorted()))"))
                                .font(.caption2.weight(.medium)).foregroundStyle(TesseraeTheme.accent)
                        }
                        HStack(spacing: 6) {
                            Text(dashboard.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(
                                    dashboard.missing ? .secondary : .primary
                                )

                            if dashboard.missing {
                                Text("Missing")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(TesseraeTheme.danger)
                            }
                        }

                        if let metadata = dashboardMetadata(
                            dashboard,
                            lineup: lineup
                        ) {
                            Text(metadata)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        stepPlanTimes(dashboard, lineup: lineup)
                    }

                    Spacer(minLength: 4)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(dashboard.missing)
            .accessibilityLabel("Preview \(dashboard.name)")
            .accessibilityIdentifier(
                "lineup-dashboard-\(dashboard.pageID)"
            )

            if model.supportsLineupControl {
                if navigation.allSelectedTargetsMatch {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TesseraeTheme.accent)
                        .frame(width: 38, height: 38)
                        .background(
                            TesseraeTheme.accent.opacity(0.11),
                            in: Circle()
                        )
                        .accessibilityLabel(String(localized: "\(dashboard.name) is a schedule step"))
                        .accessibilityIdentifier(
                            "lineup-schedule-step-\(dashboard.pageID)"
                        )
                } else {
                    Button {
                        runPaintAction(
                            .play,
                            lineup: lineup,
                            pageID: dashboard.pageID
                        )
                    } label: {
                        Image(systemName: "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(TesseraeTheme.accent)
                            .frame(width: 38, height: 38)
                            .background(
                                TesseraeTheme.accent.opacity(0.11),
                                in: Circle()
                            )
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(
                        dashboard.missing
                            || selectedTargets.isEmpty
                            || isOperating
                    )
                    .opacity(
                        dashboard.missing
                            || selectedTargets.isEmpty
                            || isOperating
                            ? 0.45
                            : 1
                    )
                    .accessibilityLabel("Send \(dashboard.name)")
                    .accessibilityIdentifier("lineup-play-\(dashboard.pageID)")
                }
            }
        }
        .padding(.vertical, 10)
    }

    private func webManagedBanner(_ lineup: Lineup) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(TesseraeTheme.warning)

            VStack(alignment: .leading, spacing: 3) {
                Text("Edit on the web")
                    .font(.subheadline.weight(.semibold))
                Text(advancedSetupMessage(lineup))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TesseraeTheme.warning.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func advancedSetupMessage(_ lineup: Lineup) -> String {
        let homeDashboardName: String?
        if let homePageID = lineup.homePageID {
            homeDashboardName = pageName(homePageID, in: lineup)
        } else if let timeout = lineup.homeTimeoutMinutes,
                  timeout > 0
        {
            homeDashboardName = lineup.dashboards.first?.name
        } else {
            homeDashboardName = nil
        }

        return lineupAdvancedSetupMessage(
            reason: lineup.requiresWebReason,
            homeDashboardName: homeDashboardName,
            homeTimeoutMinutes: lineup.homeTimeoutMinutes
        )
    }

    private var readOnlyBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Read only")
                    .font(.subheadline.weight(.semibold))
                Text("This server does not advertise app controls for Lineups.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private func secondaryDetailsCard(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            targetRow(lineup)

            if hasBehaviorDetails(lineup) {
                Divider()
                    .padding(.vertical, 12)

                Button {
                    detailsExpanded.toggle()
                } label: {
                    detailLayout {
                        Label(
                            detailsHeading(lineup),
                            systemImage: "slider.horizontal.3"
                        )
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                        if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                        Text(behaviorSummary(lineup))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(detailsExpanded ? 180 : 0))
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(detailsExpanded ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("lineup-details-disclosure")

                if detailsExpanded {
                    behaviorDetails(lineup)
                        .padding(.top, 14)
                }
            }
        }
        .tesseraeCard()
    }

    @ViewBuilder
    private func targetRow(_ lineup: Lineup) -> some View {
        let deviceIDs = displayDeviceIDs(for: lineup)
        if deviceIDs.count > 1 {
            Button {
                targetsPresented = true
            } label: {
                detailLayout {
                    Label("Targets", systemImage: "display.2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                    Text(targetSummary(lineup))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("lineup-targets")
        } else if !deviceIDs.isEmpty {
            detailLayout {
                Label("Target", systemImage: "display")
                    .font(.subheadline.weight(.semibold))

                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                Text(displayNames(deviceIDs))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            detailLayout {
                Label("Target", systemImage: "display")
                    .font(.subheadline.weight(.semibold))

                if !dynamicTypeSize.isAccessibilitySize { Spacer() }

                Text(
                    String(localized: "No display")
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func behaviorDetails(_ lineup: Lineup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch lineup.intent {
            case .daily:
                if let firesAt = lineup.firesAt {
                    valueRow("Time", firesAt)
                }
                scheduleDaysRow(lineup)
            case .interval:
                if let interval = lineup.intervalMinutes {
                    valueRow(
                        "Frequency",
                        String(localized: "Every \(minutesText(interval))")
                    )
                }
                scheduleDaysRow(lineup)
            case .cycle:
                if let anchor = lineup.anchor {
                    valueRow("Starts each day at", anchor)
                }
                scheduleDaysRow(lineup)
            case .manual:
                EmptyView()
            case nil:
                valueRow("Advance", lineup.advance.displayName)
                if let trigger = lineup.trigger {
                    valueRow("Trigger", trigger.displayName)
                }
            }

            if lineup.advance != .manual {
                if let days = lineup.daysOfWeek {
                    if lineup.intent == nil {
                        valueRow("Days", daysText(days))
                    }
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
                if let fallback = lineup.fallbackPageID {
                    valueRow("Fallback dashboard", pageName(fallback, in: lineup))
                }
                if lineup.mode == .priority {
                    valueRow(
                        "When schedules overlap",
                        lineup.priority.map { String(localized: "Priority \($0)") }
                            ?? String(localized: "Priority")
                    )
                    if let minimumHold = lineup.minHoldMinutes,
                       minimumHold > 0
                    {
                        valueRow("Minimum display time", minutesText(minimumHold))
                    }
                }
            }
            if let refresh = lineup.refreshIntervalMinutes {
                valueRow(
                    "Background refresh",
                    refresh == 0 ? String(localized: "Off") : minutesText(refresh)
                )
            }
            if let home = lineup.homePageID {
                valueRow("Home dashboard", pageName(home, in: lineup))
            }
            if let timeout = lineup.homeTimeoutMinutes,
               lineup.homePageID != nil || timeout > 0
            {
                valueRow(
                    "Return home",
                    timeout == 0 ? String(localized: "Off") : minutesText(timeout)
                )
            }
            if let entry = lineup.entryPageID,
               entry != lineup.dashboards.first?.pageID
            {
                valueRow("Entry dashboard", pageName(entry, in: lineup))
            }
        }
    }

    @ViewBuilder
    private func scheduleDaysRow(_ lineup: Lineup) -> some View {
        if let days = lineup.daysOfWeek {
            valueRow("Days", daysText(days))
        }
    }

    private func valueRow(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func effectiveSelectedDeviceIDs(for lineup: Lineup) -> Set<String> {
        didLoadInitialTargets
            ? selectedDeviceIDs
            : Set(displayDeviceIDs(for: lineup))
    }

    private func targetSummary(_ lineup: Lineup) -> String {
        let selectedTargets = presentationDeviceIDs(for: lineup)
        let availableTargetCount = displayDeviceIDs(for: lineup).count
        if selectedTargets.isEmpty {
            return String(localized: "No targets")
        }
        if selectedTargets.count == 1,
           let deviceID = selectedTargets.first
        {
            return displayName(deviceID)
        }
        if selectedTargets.count == availableTargetCount {
            return String(localized: "All \(selectedTargets.count) displays")
        }
        return String(
            localized: "\(selectedTargets.count) of \(availableTargetCount) displays"
        )
    }

    private func presentationDeviceIDs(for lineup: Lineup) -> Set<String> {
        return effectiveSelectedDeviceIDs(for: lineup)
    }

    private func displayDeviceIDs(for lineup: Lineup) -> [String] {
        resolvedLineupDeviceIDs(
            explicitDeviceIDs: lineup.deviceIDs,
            serverResolvedDeviceIDs: lineup.resolvedDeviceIDs
        )
    }

    private func displayNames(_ deviceIDs: [String]) -> String {
        deviceIDs.map(displayName).joined(separator: ", ")
    }

    private func behaviorSummary(_ lineup: Lineup) -> String {
        switch lineup.intent {
        case .daily:
            if let firesAt = lineup.firesAt {
                return String(localized: "Daily at \(firesAt)")
            }
            return String(localized: "Daily")
        case .interval:
            if let interval = lineup.intervalMinutes {
                return String(localized: "Every \(minutesText(interval))")
            }
            return String(localized: "Interval")
        case .cycle:
            if let anchor = lineup.anchor {
                return String(localized: "Starts at \(anchor)")
            }
            return String(localized: "Timed rotation")
        case .manual:
            if let refresh = lineup.refreshIntervalMinutes, refresh > 0 {
                return String(localized: "Refresh every \(minutesText(refresh))")
            }
            return String(localized: "Manual")
        case nil:
            return lineup.advance.displayName
        }
    }

    private func detailsHeading(_ lineup: Lineup) -> String {
        switch lineup.intent {
        case .daily, .interval:
            String(localized: "Schedule")
        case .cycle:
            String(localized: "Timing")
        case .manual:
            String(localized: "Details")
        case nil:
            String(localized: "Schedule & Details")
        }
    }

    private func hasBehaviorDetails(_ lineup: Lineup) -> Bool {
        let hasCommonDetails = lineup.refreshIntervalMinutes != nil
            || lineup.homePageID != nil
            || (lineup.homeTimeoutMinutes ?? 0) > 0
            || (
                lineup.entryPageID != nil
                    && lineup.entryPageID != lineup.dashboards.first?.pageID
            )

        switch lineup.intent {
        case .manual:
            return hasCommonDetails
        case .daily:
            return hasCommonDetails
                || lineup.firesAt != nil
                || lineup.daysOfWeek != nil
                || hasScheduleConstraints(lineup)
        case .interval:
            return hasCommonDetails
                || lineup.intervalMinutes != nil
                || lineup.daysOfWeek != nil
                || hasScheduleConstraints(lineup)
        case .cycle:
            return hasCommonDetails
                || lineup.anchor != nil
                || lineup.daysOfWeek != nil
                || hasScheduleConstraints(lineup)
        case nil:
            return true
        }
    }

    private func hasScheduleConstraints(_ lineup: Lineup) -> Bool {
        lineup.endAt != nil
            || lineup.windowStart != nil
            || lineup.windowEnd != nil
            || lineup.fallbackPageID != nil
            || lineup.mode == .priority
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
                deviceIDs: Array(controlTargetIDs(for: lineup)).sorted()
            )
        }
    }

    private func reconcileTargets(_ boundDeviceIDs: [String]) {
        let bound = Set(boundDeviceIDs)
        if !didLoadInitialTargets {
            didLoadInitialTargets = true
            if let originatingDisplayID, bound.contains(originatingDisplayID), model.displays.contains(where: { $0.id == originatingDisplayID }) {
                selectedDeviceIDs = [originatingDisplayID]
            } else {
                selectedDeviceIDs = bound
            }
            return
        }
        selectedDeviceIDs.formIntersection(bound)
    }

    private func displayName(_ deviceID: String) -> String {
        model.displays.first { $0.id == deviceID }?.name ?? deviceID
    }

    private func dashboardMetadata(
        _ dashboard: LineupDashboard,
        lineup: Lineup
    ) -> String? {
        var parts: [String] = []
        if lineup.trigger == .cycle {
            parts.append(minutesText(dashboard.dwellMinutes))
        }
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
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        return lineupWebURL(
            lineup.webURL,
            lineupID: lineup.id,
            relativeTo: baseURL
        )
    }

    private func beginEditingLineup() {
        if model.lineupAuthoringPermission == .denied {
            Task {
                await model.refreshLineupAuthoringPermission()
                if model.lineupAuthoringPermission == .denied {
                    authoringPermissionAlertPresented = true
                } else {
                    editingLineup = true
                }
            }
        } else {
            editingLineup = true
        }
    }
}

func lineupWebURL(
    _ webURL: String,
    lineupID: String,
    relativeTo baseURL: URL
) -> URL? {
    var resolvedPath = webURL

    if var components = URLComponents(string: webURL),
       components.scheme == nil,
       components.host == nil,
       components.query == nil,
       components.fragment == nil,
       components.path.hasPrefix("/"),
       components.path.split(separator: "/").map(String.init) == ["decks", lineupID]
    {
        components.path += "/edit"
        resolvedPath = components.string ?? webURL
    }

    return URL(string: resolvedPath, relativeTo: baseURL)?.absoluteURL
}

func lineupAdvancedSetupMessage(
    reason: String?,
    homeDashboardName: String?,
    homeTimeoutMinutes: Int?
) -> String {
    if reason == "has a home dashboard" {
        if let timeout = homeTimeoutMinutes, timeout > 0 {
            let duration = timeout == 1
                ? String(localized: "1 minute")
                : String(localized: "\(timeout) minutes")
            if let homeDashboardName {
                return String(
                    localized: "\(homeDashboardName) is shown first. After \(duration) of inactivity, this Lineup returns to it. Edit this in Tesserae on the web."
                )
            }
            return String(
                localized: "The home dashboard is shown first and returns after \(duration) of inactivity. Edit this in Tesserae on the web."
            )
        }

        if let homeDashboardName, homeTimeoutMinutes == 0 {
            return String(
                localized: "\(homeDashboardName) is shown first when this Lineup is pushed. Automatic return is off. Edit this in Tesserae on the web."
            )
        }

        return String(
            localized: "A home dashboard is configured, but this server does not provide its return timing to the app. View or change it in Tesserae on the web."
        )
    }

    if let reason {
        return String(
            localized: "This Lineup \(reason). Edit this in Tesserae on the web."
        )
    }

    return String(localized: "This Lineup is edited in Tesserae on the web.")
}

struct DisplayPlanSummary: View {
    let plan: DisplayPlanProjection
    var showsDisplayName = false
    var showsNextHeading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if showsDisplayName { Text(plan.displayName).font(.caption.weight(.semibold)) }
            if let next = plan.next {
                Text((showsNextHeading ? String(localized: "Next planned update") + " · " : "") + plannedEventTime(next))
                    .foregroundStyle(TesseraeTheme.info)
                Text([next.event.dashboardName, next.event.lineupName, plannedCertaintyTitle(next.event.certainty), next.event.effect == .changeScreen ? String(localized: "Changes the screen") : String(localized: "Refreshes the current screen")].compactMap { $0 }.joined(separator: " · "))
            } else {
                Text(plan.status)
            }
            if let response = plan.response, plan.next == nil || plan.error != nil {
                Text(String(localized: "Projection generated \(projectionDateText(response.generatedAt, timezone: response.timezone)) · Through \(projectionDateText(response.throughAt, timezone: response.timezone))"))
                    .font(.caption2)
            }
            if plan.error != nil, plan.response != nil {
                Text("Previous projection · Refresh failed")
            }
            if let error = plan.error, plan.response != nil { Text(error) }
            if plan.isRefreshing, plan.response != nil { Text("Refreshing…") }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }


}

private struct LineupStepThumbnail: View {
    @Environment(AppModel.self) private var model
    let dashboard: LineupDashboard
    let display: DisplaySummary?

    var body: some View {
        Group {
            if let display {
                PreviewArtwork(
                    state: model.dashboardPreview(id: dashboard.pageID, deviceID: display.id),
                    placeholderSystemName: "rectangle.grid.2x2",
                    placeholderLabel: String(localized: "Preview \(dashboard.name)"),
                    imageLabel: String(localized: "Preview \(dashboard.name)"),
                    accessibilityIdentifier: "lineup-step-thumbnail-\(dashboard.pageID)"
                )
                .aspectRatio(CGFloat(display.panel.width) / CGFloat(max(display.panel.height, 1)), contentMode: .fit)
            } else {
                Image(systemName: "rectangle.grid.2x2")
                    .foregroundStyle(.secondary)
                    .frame(width: 64, height: 48)
                    .background(Color.secondary.opacity(0.06))
                    .accessibilityLabel("Select one display for step previews")
            }
        }
        .frame(width: 64)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .task(id: "\(dashboard.pageID)|\(display?.id ?? "none")|\(model.previewGeneration)") {
            guard let display, !dashboard.missing else { return }
            await model.loadDashboardPreview(id: dashboard.pageID, deviceID: display.id)
        }
    }
}


private struct LineupTargetSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var hapticEvent = TesseraeHapticEvent()

    let deviceIDs: [String]
    let displays: [DisplaySummary]
    @Binding var selection: Set<String>

    var body: some View {
        NavigationStack {
            List {
                ForEach(deviceIDs, id: \.self) { deviceID in
                    Button {
                        if selection.contains(deviceID) {
                            selection.remove(deviceID)
                        } else {
                            selection.insert(deviceID)
                        }
                        hapticEvent.trigger(.selection)
                    } label: {
                        TesseraeDisplaySelectionRow(
                            name: displayName(deviceID),
                            resolution: displayResolution(deviceID),
                            isSelected: selection.contains(deviceID)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("lineup-target-\(deviceID)")
                }
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle("Targets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Select All") {
                        guard selection.count != deviceIDs.count else { return }
                        selection = Set(deviceIDs)
                        hapticEvent.trigger(.selection)
                    }
                    .disabled(selection.count == deviceIDs.count)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
            }
        }
        .tesseraeHapticFeedback(trigger: hapticEvent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func displayName(_ deviceID: String) -> String {
        displays.first { $0.id == deviceID }?.name ?? deviceID
    }

    private func displayResolution(_ deviceID: String) -> String {
        guard let display = displays.first(where: { $0.id == deviceID }) else {
            return String(localized: "Unavailable")
        }
        return "\(display.panel.width)×\(display.panel.height)"
    }
}

private extension LineupIntent {
    var displayName: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .interval: String(localized: "Keep Fresh")
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

#if DEBUG
#Preview("Lineups") {
    TesseraePreviewHost {
        NavigationStack {
            LineupsView(isActive: false)
        }
    }
}
#endif
