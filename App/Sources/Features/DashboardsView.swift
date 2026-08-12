import SwiftUI
import TesseraeKit
import UIKit

private struct DashboardOccurrenceID: Hashable {
    let sectionID: String
    let dashboardID: String

    var accessibilitySuffix: String {
        "\(dashboardID)-\(sectionID)"
    }
}

private struct DashboardSection: Identifiable {
    enum Kind {
        case display(DisplaySummary)
        case shared
        case unassigned
    }

    let id: String
    let kind: Kind
    let dashboards: [DashboardSummary]
}

private enum DashboardLayoutMode: String {
    case cards
    case list
}

private struct DashboardPushContext: Identifiable {
    enum Scope {
        case display(DisplaySummary)
        case shared([DisplaySummary])
        case unassigned
    }

    let dashboard: DashboardSummary
    let scope: Scope

    var id: String {
        switch scope {
        case let .display(display):
            "\(dashboard.id)|display|\(display.id)"
        case .shared:
            "\(dashboard.id)|shared"
        case .unassigned:
            "\(dashboard.id)|unassigned"
        }
    }

    var previewDeviceID: String? {
        switch scope {
        case let .display(display):
            display.id
        case let .shared(displays):
            displays.first?.id
        case .unassigned:
            nil
        }
    }

    var initialDeviceIDs: Set<String> {
        switch scope {
        case let .display(display):
            [display.id]
        case let .shared(displays):
            Set(displays.map(\.id))
        case .unassigned:
            []
        }
    }

    var boundDisplays: [DisplaySummary] {
        switch scope {
        case let .display(display):
            [display]
        case let .shared(displays):
            displays
        case .unassigned:
            []
        }
    }

    var showsDisplayPicker: Bool {
        if case .display = scope {
            false
        } else {
            true
        }
    }
}

struct DashboardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var draggedOccurrenceID: DashboardOccurrenceID?
    @State private var dropTargetOccurrenceID: DashboardOccurrenceID?
    @State private var expandedOccurrenceID: DashboardOccurrenceID?
    @State private var dashboardToPush: DashboardPushContext?
    @State private var sectionContentHeights: [String: CGFloat] = [:]
    @AppStorage("dashboardLayoutMode")
    private var layoutMode = DashboardLayoutMode.cards
    private let previewCanvasSize = CGSize(width: 112, height: 118)

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    private var dashboardSections: [DashboardSection] {
        let dashboards = model.sortedDashboards
        let displays = model.sortedDisplays
        let displayIDs = Set(displays.map(\.id))
        var sections = displays.compactMap { display -> DashboardSection? in
            let matching = dashboards.filter {
                $0.deviceIDs.contains(display.id)
            }
            guard !matching.isEmpty else { return nil }
            return DashboardSection(
                id: "display-\(display.id)",
                kind: .display(display),
                dashboards: matching
            )
        }
        let shared = dashboards.filter { dashboard in
            dashboard.deviceIDs.filter(displayIDs.contains).count > 1
        }
        if !shared.isEmpty {
            sections.append(
                DashboardSection(
                    id: "shared",
                    kind: .shared,
                    dashboards: shared
                )
            )
        }
        let unassigned = dashboards.filter { dashboard in
            dashboard.deviceIDs.allSatisfy { !displayIDs.contains($0) }
        }
        if !unassigned.isEmpty {
            sections.append(
                DashboardSection(
                    id: "unassigned",
                    kind: .unassigned,
                    dashboards: unassigned
                )
            )
        }
        return sections
    }

    var body: some View {
        let sections = dashboardSections
        let dashboardOrder = sections.flatMap(\.dashboards).map(\.id)

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                ForEach(sections) { section in
                    let isCollapsed = model.collapsedDashboardSectionIDs.contains(
                        section.id
                    )

                    VStack(alignment: .leading, spacing: 0) {
                        dashboardSectionHeader(section)

                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(section.dashboards) { dashboard in
                                let occurrenceID = DashboardOccurrenceID(
                                    sectionID: section.id,
                                    dashboardID: dashboard.id
                                )
                                let pushContext = pushContext(
                                    for: dashboard,
                                    in: section
                                )

                                dashboardCard(
                                    dashboard,
                                    occurrenceID: occurrenceID,
                                    pushContext: pushContext
                                )
                                .onDrag {
                                    draggedOccurrenceID = occurrenceID
                                    return NSItemProvider(
                                        object: dashboard.id as NSString
                                    )
                                } preview: {
                                    dashboardDragPreview(dashboard)
                                }
                                .dropDestination(
                                    for: String.self
                                ) { items, _ in
                                    defer { endDashboardDrag() }
                                    return items.first != nil
                                } isTargeted: { targeted in
                                    updateDropTarget(
                                        occurrenceID,
                                        targeted: targeted
                                    )
                                }
                                .overlay {
                                    if dropTargetOccurrenceID == occurrenceID {
                                        RoundedRectangle(
                                            cornerRadius: 16,
                                            style: .continuous
                                        )
                                        .strokeBorder(
                                            TesseraeTheme.accent.opacity(0.8),
                                            lineWidth: 2
                                        )
                                        .allowsHitTesting(false)
                                        .transition(.opacity)
                                    }
                                }
                                .animation(
                                    .spring(
                                        response: 0.28,
                                        dampingFraction: 0.82
                                    ),
                                    value: dashboardOrder
                                )
                                .accessibilityHint(
                                    "Long press and drag to reorder within this section."
                                )
                                .task(
                                    id: isCollapsed || layoutMode == .list
                                        ? nil
                                        : model.previewGeneration
                                ) {
                                    guard !isCollapsed, layoutMode == .cards else {
                                        return
                                    }
                                    do {
                                        try await Task.sleep(
                                            for: .milliseconds(260)
                                        )
                                    } catch {
                                        return
                                    }
                                    await model.loadDashboardPreview(
                                        dashboard,
                                        deviceID: pushContext.previewDeviceID
                                    )
                                }
                                .allowsHitTesting(!isCollapsed)
                            }
                        }
                        .padding(.top, 10)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            guard height > 0 else { return }
                            sectionContentHeights[section.id] = height
                        }
                        .frame(
                            height: isCollapsed
                                ? 0
                                : sectionContentHeights[section.id],
                            alignment: .top
                        )
                        .clipped()
                        .allowsHitTesting(!isCollapsed)
                    }
                }
            }
            .padding(16)
        }
        .refreshable {
            await model.refreshDashboards()
        }
        .sheet(item: $dashboardToPush) { context in
            DashboardPushSheet(context: context)
                .environment(model)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    toggleLayoutMode()
                } label: {
                    Label(
                        layoutMode == .cards
                            ? "Use List View"
                            : "Use Card View",
                        systemImage: layoutMode == .cards
                            ? "rectangle.stack"
                            : "list.bullet"
                    )
                }
                .accessibilityIdentifier("dashboard-layout-toggle")
            }
        }
        .overlay {
            if (model.isRefreshingDashboards || model.isRefreshing)
                && model.dashboards.isEmpty
            {
                ProgressView("Loading dashboards…")
            } else if model.dashboards.isEmpty {
                ContentUnavailableView {
                    Label("No Dashboards", systemImage: "rectangle.grid.2x2")
                } description: {
                    Text("Create a Dashboard in Tesserae's web interface, then refresh.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refreshDashboards() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task(id: shouldAutoRefresh) {
            guard shouldAutoRefresh else { return }

            await model.refreshDashboards(
                showErrors: false,
                saveSnapshot: false
            )
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                await model.refreshDashboards(
                    showErrors: false,
                    saveSnapshot: false
                )
            }
        }
        .tesseraeScreenBackground()
    }

    private func dashboardSectionHeader(
        _ section: DashboardSection
    ) -> some View {
        let isCollapsed = model.collapsedDashboardSectionIDs.contains(
            section.id
        )

        return Button {
            toggleSection(section)
        } label: {
            HStack(spacing: 10) {
                sectionIcon(section)
                    .foregroundStyle(TesseraeTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        TesseraeTheme.accent.opacity(0.11),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(sectionTitle(section))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    if let subtitle = sectionSubtitle(section) {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(section.dashboards.count, format: .number)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Color.primary.opacity(0.055),
                        in: Capsule()
                    )

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(
                        .degrees(isCollapsed ? -90 : 0)
                    )
                    .frame(width: 16)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(sectionTitle(section))
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
        .accessibilityHint(
            isCollapsed ? "Expands this group." : "Collapses this group."
        )
        .accessibilityIdentifier("dashboard-section-toggle-\(section.id)")
    }

    @ViewBuilder
    private func sectionIcon(_ section: DashboardSection) -> some View {
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
        case .shared, .unassigned:
            Image(systemName: sectionSymbol(section))
                .font(.subheadline.weight(.semibold))
        }
    }

    private func toggleSection(_ section: DashboardSection) {
        let isCollapsing = !model.collapsedDashboardSectionIDs.contains(
            section.id
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if isCollapsing,
               expandedOccurrenceID?.sectionID == section.id
            {
                expandedOccurrenceID = nil
            }
            model.setDashboardSectionCollapsed(
                section.id,
                isCollapsed: isCollapsing
            )
        }
    }

    private func toggleLayoutMode() {
        if layoutMode == .cards {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                expandedOccurrenceID = nil
                layoutMode = .list
            }
        } else {
            layoutMode = .cards
        }
    }

    private func sectionSymbol(_ section: DashboardSection) -> String {
        switch section.kind {
        case let .display(display):
            display.panel.height > display.panel.width
                ? "rectangle.portrait.inset.filled"
                : "rectangle.inset.filled"
        case .shared:
            "rectangle.3.group.fill"
        case .unassigned:
            "rectangle.badge.xmark"
        }
    }

    private func sectionTitle(_ section: DashboardSection) -> String {
        switch section.kind {
        case let .display(display):
            display.name
        case .shared:
            String(localized: "Shared Displays")
        case .unassigned:
            String(localized: "Unassigned")
        }
    }

    private func sectionSubtitle(_ section: DashboardSection) -> String? {
        switch section.kind {
        case .display:
            nil
        case .shared:
            String(localized: "Dashboards bound to multiple displays")
        case .unassigned:
            String(localized: "Not bound to an available display")
        }
    }

    private func pushContext(
        for dashboard: DashboardSummary,
        in section: DashboardSection
    ) -> DashboardPushContext {
        switch section.kind {
        case let .display(display):
            return DashboardPushContext(
                dashboard: dashboard,
                scope: .display(display)
            )
        case .shared:
            let boundIDs = Set(dashboard.deviceIDs)
            return DashboardPushContext(
                dashboard: dashboard,
                scope: .shared(
                    model.sortedDisplays.filter { boundIDs.contains($0.id) }
                )
            )
        case .unassigned:
            return DashboardPushContext(
                dashboard: dashboard,
                scope: .unassigned
            )
        }
    }

    @ViewBuilder
    private func dashboardCard(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID,
        pushContext: DashboardPushContext
    ) -> some View {
        let expandedImage = layoutMode == .cards
            ? dashboardPreviewImage(for: pushContext)
            : nil
        let isExpanded = expandedOccurrenceID == occurrenceID

        VStack(
            alignment: .leading,
            spacing: layoutMode == .cards && isExpanded ? 14 : 0
        ) {
            if layoutMode == .cards {
                HStack(alignment: .center, spacing: 12) {
                    dashboardIdentityIcon(dashboard)

                    dashboardCardDetails(
                        dashboard,
                        occurrenceID: occurrenceID,
                        pushContext: pushContext
                    )

                    dashboardPreview(
                        dashboard,
                        occurrenceID: occurrenceID,
                        context: pushContext,
                        canExpand: expandedImage != nil,
                        isExpanded: isExpanded
                    )
                }

                if let expandedImage, isExpanded {
                    expandedDashboardPreview(
                        expandedImage,
                        dashboard: dashboard,
                        occurrenceID: occurrenceID
                    )
                    .transition(.opacity)
                }
            } else {
                Button {
                    dashboardToPush = pushContext
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        dashboardIdentityIcon(dashboard)

                        dashboardListDetails(
                            dashboard,
                            occurrenceID: occurrenceID,
                            pushContext: pushContext
                        )

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    "dashboard-row-\(occurrenceID.accessibilitySuffix)"
                )
                .accessibilityHint("Opens Dashboard preview and Push options.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .contentShape(
            .dragPreview,
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func dashboardCardDetails(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID,
        pushContext: DashboardPushContext
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            dashboardTitle(dashboard, occurrenceID: occurrenceID)

            Text(dashboard.kind.rawValue.capitalized)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            if let targetDescription = cardTargetDescription(pushContext) {
                Label(
                    targetDescription,
                    systemImage: "rectangle.connected.to.line.below"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            }

            dashboardPushButton(
                dashboard,
                occurrenceID: occurrenceID,
                pushContext: pushContext
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dashboardListDetails(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID,
        pushContext: DashboardPushContext
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            dashboardTitle(dashboard, occurrenceID: occurrenceID)

            Text(dashboardListSubtitle(dashboard, context: pushContext))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dashboardTitle(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID
    ) -> some View {
        Text(dashboard.name)
            .font(.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.82)
            .layoutPriority(1)
            .accessibilityIdentifier(
                "dashboard-title-\(occurrenceID.accessibilitySuffix)"
            )
    }

    private func dashboardPushButton(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID,
        pushContext: DashboardPushContext
    ) -> some View {
        Button {
            dashboardToPush = pushContext
        } label: {
            HStack(spacing: 5) {
                if model.activeOperationIDs.contains(dashboard.id) {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "paperplane.fill")
                }
                Text("Push")
            }
            .font(.caption.weight(.semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(
            "dashboard-push-\(occurrenceID.accessibilitySuffix)"
        )
        .disabled(
            pushContext.initialDeviceIDs.isEmpty
                || model.activeOperationIDs.contains(dashboard.id)
        )
    }

    private func dashboardListSubtitle(
        _ dashboard: DashboardSummary,
        context: DashboardPushContext
    ) -> String {
        var parts = [dashboard.kind.rawValue.capitalized]
        if let targetDescription = cardTargetDescription(context) {
            parts.append(targetDescription)
        }
        return parts.joined(separator: " · ")
    }

    private func cardTargetDescription(
        _ context: DashboardPushContext
    ) -> String? {
        switch context.scope {
        case .display:
            nil
        case let .shared(displays):
            displays.map(\.name).joined(separator: ", ")
        case .unassigned:
            String(localized: "No displays")
        }
    }

    private func dashboardIdentityIcon(
        _ dashboard: DashboardSummary
    ) -> some View {
        PhosphorIcon(
            name: dashboard.canonicalIconName,
            size: 18,
            color: TesseraeTheme.accent
        )
        .frame(width: 36, height: 36)
        .background(
            TesseraeTheme.accent.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityHidden(true)
    }

    private func dashboardPreview(
        _ dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID,
        context: DashboardPushContext,
        canExpand: Bool,
        isExpanded: Bool
    ) -> some View {
        let previewSize = dashboardPreviewSize(for: context)
        let preview = ZStack {
            Color.clear

            PreviewArtwork(
                state: model.dashboardPreview(
                    for: dashboard,
                    deviceID: context.previewDeviceID
                ),
                placeholderSystemName: dashboard.kind == .canvas
                    ? "scribble.variable"
                    : "square.grid.2x2",
                placeholderLabel: "Dashboard preview placeholder",
                imageLabel: "Cached visual preview for \(dashboard.name)",
                accessibilityIdentifier: "dashboard-preview-\(occurrenceID.accessibilitySuffix)"
            )
            .frame(
                width: CGFloat(previewSize.width),
                height: CGFloat(previewSize.height)
            )
        }
        .frame(
            width: previewCanvasSize.width,
            height: previewCanvasSize.height
        )

        return Button {
            guard canExpand else { return }
            withAnimation(.smooth(duration: 0.28)) {
                expandedOccurrenceID = isExpanded ? nil : occurrenceID
            }
        } label: {
            preview
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(
            "dashboard-preview-button-\(occurrenceID.accessibilitySuffix)"
        )
        .accessibilityLabel("Preview \(dashboard.name)")
        .accessibilityValue(
            isExpanded ? Text("Expanded") : Text("Collapsed")
        )
        .accessibilityHint(
            canExpand
                ? Text(
                    isExpanded
                        ? "Collapse dashboard preview"
                        : "Expand dashboard preview"
                )
                : Text("Dashboard preview unavailable")
        )
        .disabled(!canExpand)
    }

    private func dashboardPreviewImage(
        for context: DashboardPushContext
    ) -> UIImage? {
        model.dashboardPreview(
            for: context.dashboard,
            deviceID: context.previewDeviceID
        )?
            .data
            .flatMap(UIImage.init(data:))
    }

    private func expandedDashboardPreview(
        _ image: UIImage,
        dashboard: DashboardSummary,
        occurrenceID: DashboardOccurrenceID
    ) -> some View {
        FittedPreviewLayout(
            aspectRatio: image.size.width / image.size.height,
            maximumHeight: 420
        ) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
        }
        .frame(maxWidth: .infinity)
        .background(
            Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .clipShape(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
        )
        .accessibilityIdentifier(
            "dashboard-preview-expanded-\(occurrenceID.accessibilitySuffix)"
        )
        .accessibilityLabel("Expanded preview for \(dashboard.name)")
    }

    private func dashboardPreviewSize(
        for context: DashboardPushContext
    ) -> CGSize {
        guard
            let targetID = context.previewDeviceID,
            let target = model.displays.first(where: { $0.id == targetID })
        else {
            return previewCanvasSize
        }

        let size = target.panel.fittedPreviewSize(
            maxWidth: previewCanvasSize.width,
            maxHeight: previewCanvasSize.height
        )
        return CGSize(
            width: CGFloat(size.width),
            height: CGFloat(size.height)
        )
    }

    private func dashboardDragPreview(
        _ dashboard: DashboardSummary
    ) -> some View {
        ReorderDragPreview(title: dashboard.name) {
            PhosphorIcon(
                name: dashboard.canonicalIconName,
                size: 17,
                color: .white
            )
        }
        .onDisappear {
            endDashboardDrag()
        }
    }

    private func updateDropTarget(
        _ targetOccurrenceID: DashboardOccurrenceID,
        targeted: Bool
    ) {
        guard targeted else {
            if dropTargetOccurrenceID == targetOccurrenceID {
                withAnimation(.easeOut(duration: 0.12)) {
                    dropTargetOccurrenceID = nil
                }
            }
            return
        }

        guard
            let sourceOccurrenceID = draggedOccurrenceID,
            sourceOccurrenceID.sectionID == targetOccurrenceID.sectionID
        else {
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetOccurrenceID = targetOccurrenceID
        }

        guard
            sourceOccurrenceID.dashboardID != targetOccurrenceID.dashboardID,
            let targetIndex = model.sortedDashboards.firstIndex(
                where: { $0.id == targetOccurrenceID.dashboardID }
            )
        else {
            return
        }

        withAnimation(
            .spring(
                response: 0.28,
                dampingFraction: 0.82
            )
        ) {
            model.moveDashboard(
                sourceOccurrenceID.dashboardID,
                to: targetIndex
            )
        }
    }

    private func endDashboardDrag() {
        withAnimation(.easeOut(duration: 0.12)) {
            draggedOccurrenceID = nil
            dropTargetOccurrenceID = nil
        }
    }
}

private struct DashboardPushSheet: View {
    let context: DashboardPushContext

    var body: some View {
        DashboardPreviewActionSheet(
            dashboardID: context.dashboard.id,
            dashboardName: context.dashboard.name,
            previewDeviceID: context.previewDeviceID,
            displays: context.boundDisplays,
            initialDeviceIDs: context.initialDeviceIDs,
            showsDisplayPicker: context.showsDisplayPicker,
            action: .push(context.dashboard)
        )
    }
}

enum DashboardPreviewAction {
    case push(DashboardSummary)
    case playLineup(lineupID: String, pageID: String)
}

struct DashboardPreviewActionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let dashboardID: String
    let dashboardName: String
    let previewDeviceID: String?
    let displays: [DisplaySummary]
    let initialDeviceIDs: Set<String>
    let showsDisplayPicker: Bool
    let action: DashboardPreviewAction

    @State private var selectedDeviceIDs: Set<String> = []
    @State private var didLoadInitialSelection = false
    @State private var contentHeight: CGFloat = 1
    @State private var sheetHeight: CGFloat = 400

    private let maximumContentHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text(sheetTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("\(identifierPrefix)-sheet-title")

                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .tesseraeModalChromeButtonStyle()
                    Spacer()
                }
            }
            .padding(.horizontal, TesseraeComposerLayout.pagePadding)
            .padding(.top, 24)
            .padding(.bottom, 12)

            ScrollView {
                dashboardPushContent
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { measuredHeight in
                        contentHeight = measuredHeight
                    }
            }
            .frame(height: min(contentHeight, maximumContentHeight))
            .scrollDisabled(contentHeight <= maximumContentHeight)

            Button {
                Task {
                    await performAction()
                }
            } label: {
                Label(
                    actionButtonTitle,
                    systemImage: actionSystemImage
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                selectedDeviceIDs.isEmpty
                    || isOperating
                    || isPlayingOnAllSelectedDisplays
                    || !canPerformAction
            )
            .padding(.horizontal, TesseraeComposerLayout.pagePadding)
            .padding(.bottom, TesseraeComposerLayout.pagePadding)
        }
        .task(id: taskID) {
            loadInitialSelection()
            await model.loadDashboardPreview(
                id: dashboardID,
                deviceID: previewDeviceID
            )
        }
        .tesseraeScreenBackground()
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { geometry in
            geometry.size.height
        } action: { measuredHeight in
            guard abs(sheetHeight - measuredHeight) > 0.5 else { return }
            sheetHeight = measuredHeight
        }
        .presentationDetents([.height(sheetHeight)])
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
    }

    private var dashboardPushContent: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.sectionSpacing
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(dashboardName)
                    .font(.title3.weight(.semibold))

                if let previewImage {
                    FittedPreviewLayout(
                        aspectRatio: previewImage.size.width
                            / previewImage.size.height,
                        maximumHeight: 220,
                        shrinksWidthAtMaximumHeight: true
                    ) {
                        Image(uiImage: previewImage)
                            .resizable()
                            .interpolation(.none)
                            .scaledToFit()
                    }
                    .background(
                        Color.primary.opacity(0.055),
                        in: RoundedRectangle(
                            cornerRadius: 15,
                            style: .continuous
                        )
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: 15,
                            style: .continuous
                        )
                    )
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier(
                        "\(identifierPrefix)-preview-\(dashboardID)"
                    )
                    .accessibilityLabel(
                        "Preview for \(dashboardName)"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tesseraeCard()

            if showsDisplayPicker {
                boundDisplaysPicker
            }
        }
        .padding(.horizontal, TesseraeComposerLayout.pagePadding)
        .padding(.top, TesseraeComposerLayout.pagePadding)
        .padding(.bottom, 12)
    }

    private var previewImage: UIImage? {
        model.dashboardPreview(
            id: dashboardID,
            deviceID: previewDeviceID
        )?
            .data
            .flatMap(UIImage.init(data:))
    }

    private var boundDeviceIDs: Set<String> {
        Set(displays.map(\.id))
    }

    private func loadInitialSelection() {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true

        selectedDeviceIDs = initialDeviceIDs
    }

    private var sheetTitle: String {
        switch action {
        case .push:
            String(localized: "Push Dashboard")
        case .playLineup:
            String(localized: "Dashboard Preview")
        }
    }

    private var identifierPrefix: String {
        switch action {
        case .push:
            "dashboard-push"
        case .playLineup:
            "lineup-dashboard"
        }
    }

    private var taskID: String {
        switch action {
        case .push:
            "push|\(dashboardID)|\(previewDeviceID ?? "default")"
        case let .playLineup(lineupID, pageID):
            "lineup|\(lineupID)|\(pageID)|\(previewDeviceID ?? "default")"
        }
    }

    private var isOperating: Bool {
        switch action {
        case let .push(dashboard):
            model.activeOperationIDs.contains(dashboard.id)
        case let .playLineup(lineupID, _):
            model.isOperatingOnLineup(lineupID)
        }
    }

    private var isPlayingOnAllSelectedDisplays: Bool {
        guard
            case let .playLineup(lineupID, pageID) = action,
            !selectedDeviceIDs.isEmpty,
            let lineup = model.lineups.first(where: { $0.id == lineupID })
        else {
            return false
        }

        return selectedDeviceIDs.allSatisfy { deviceID in
            lineup.current.contains {
                $0.deviceID == deviceID && $0.pageID == pageID
            }
        }
    }

    private var actionButtonTitle: String {
        if !canPerformAction {
            return String(localized: "Preview Only")
        }
        if isOperating {
            switch action {
            case .push:
                return String(localized: "Sending…")
            case .playLineup:
                return String(localized: "Playing…")
            }
        }
        if isPlayingOnAllSelectedDisplays {
            return String(localized: "Now Playing")
        }
        return targetActionTitle
    }

    private var canPerformAction: Bool {
        switch action {
        case .push:
            true
        case .playLineup:
            model.supportsLineupControl
        }
    }

    private var actionSystemImage: String {
        switch action {
        case .push:
            "paperplane.fill"
        case .playLineup:
            "play.fill"
        }
    }

    private var displayPickerTitle: String {
        switch action {
        case .push:
            String(localized: "Bound Displays")
        case .playLineup:
            String(localized: "Play On")
        }
    }

    private var emptyDisplaysTitle: String {
        switch action {
        case .push:
            String(localized: "No Bound Displays")
        case .playLineup:
            String(localized: "No Available Displays")
        }
    }

    private var emptyDisplaysDescription: String {
        switch action {
        case .push:
            String(
                localized: "Bind this dashboard to at least one display in Tesserae before pushing it from the app."
            )
        case .playLineup:
            String(
                localized: "This Lineup has no available display target for playback."
            )
        }
    }

    @MainActor
    private func performAction() async {
        let deviceIDs = Array(selectedDeviceIDs).sorted()
        let succeeded: Bool

        switch action {
        case let .push(dashboard):
            succeeded = await model.push(dashboard, deviceIDs: deviceIDs)
        case let .playLineup(lineupID, pageID):
            guard let lineup = model.lineups.first(where: { $0.id == lineupID })
            else {
                return
            }
            succeeded = await model.controlLineup(
                lineup,
                action: .play,
                pageID: pageID,
                deviceIDs: deviceIDs
            )
        }

        if succeeded {
            dismiss()
        }
    }

    private var targetActionTitle: String {
        if selectedDeviceIDs.count == 1,
           let selectedID = selectedDeviceIDs.first,
           let display = displays.first(where: { $0.id == selectedID })
        {
            switch action {
            case .push:
                return String(localized: "Push to \(display.name)")
            case .playLineup:
                return String(localized: "Play on \(display.name)")
            }
        }
        if selectedDeviceIDs.count > 1 {
            switch action {
            case .push:
                return String(
                    localized: "Push to \(selectedDeviceIDs.count) Displays"
                )
            case .playLineup:
                return String(
                    localized: "Play on \(selectedDeviceIDs.count) Displays"
                )
            }
        }
        switch action {
        case .push:
            return String(localized: "Push to Selected Displays")
        case .playLineup:
            return String(localized: "Play on Selected Displays")
        }
    }

    private var boundDisplaysPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(displayPickerTitle)
                    .font(.headline)
                Spacer()
                if !boundDeviceIDs.isEmpty {
                    Button("Select All") {
                        selectedDeviceIDs = boundDeviceIDs
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if displays.isEmpty {
                ContentUnavailableView {
                    Label(
                        emptyDisplaysTitle,
                        systemImage: "rectangle.badge.xmark"
                    )
                } description: {
                    Text(emptyDisplaysDescription)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(displays) { display in
                    Button {
                        if selectedDeviceIDs.contains(display.id) {
                            selectedDeviceIDs.remove(display.id)
                        } else {
                            selectedDeviceIDs.insert(display.id)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(
                                systemName: selectedDeviceIDs.contains(
                                    display.id
                                )
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                selectedDeviceIDs.contains(display.id)
                                    ? TesseraeTheme.accent
                                    : .secondary
                            )

                            Text(display.name)
                                .foregroundStyle(.primary)

                            Spacer()

                            Text(
                                "\(display.panel.width)×\(display.panel.height)"
                            )
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        "\(identifierPrefix)-device-\(display.id)"
                    )
                }
            }
        }
        .tesseraeCard()
    }
}
