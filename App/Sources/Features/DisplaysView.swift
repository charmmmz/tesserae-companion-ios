import SwiftUI
import TesseraeKit

private struct DisplayPreviewRefreshID: Hashable {
    let generation: Int
    let hasPendingRender: Bool?
    let lastSeenAt: Date?
}

struct DisplaysView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.presentTesseraeSettings) private var presentSettings
    @State private var draggedDisplayID: String?
    @State private var dropTargetDisplayID: String?
    @State private var transientDisplayOrderIDs: [String]?
    @State private var lastReorderedTargetID: String?
    @State private var reorderTargetResetTask: Task<Void, Never>?
    @State private var selectedDisplay: DisplaySummary?
    @State private var lineupsPresented = false
    @State private var hapticEvent = TesseraeHapticEvent()

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && !lineupsPresented && scenePhase == .active
    }

    private var displayedDisplays: [DisplaySummary] {
        guard let transientDisplayOrderIDs else {
            return model.sortedDisplays
        }

        let displaysByID = Dictionary(
            uniqueKeysWithValues: model.displays.map { ($0.id, $0) }
        )
        let ordered = transientDisplayOrderIDs.compactMap { displaysByID[$0] }
        let orderedIDs = Set(ordered.map(\.id))
        return ordered + model.sortedDisplays.filter { !orderedIDs.contains($0.id) }
    }

    var body: some View {
        let displays = displayedDisplays
        let displayOrder = displays.map(\.id)

        ScrollView {
            LazyVStack(spacing: 14) {
                if model.supportsLineups {
                    Button {
                        lineupsPresented = true
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "rectangle.3.group")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(TesseraeTheme.accent)
                                .frame(width: 40, height: 40)
                                .background(
                                    TesseraeTheme.accent.opacity(0.11),
                                    in: RoundedRectangle(
                                        cornerRadius: 12,
                                        style: .continuous
                                    )
                                )

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Manage Lineups")
                                    .font(.headline)
                                Text("Schedules, decks, and rotations")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            if !model.lineups.isEmpty {
                                Text("\(model.lineups.count)")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tesseraeCard()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("manage-lineups")
                    .accessibilityHint("Opens Lineups and controls.")
                }

                ForEach(displays) { display in
                    DisplayCard(
                        display: display,
                        preview: model.displayPreviews[display.id]
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedDisplay = display
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("display-card-\(display.id)")
                    .accessibilityAddTraits(.isButton)
                    .onDrag {
                        draggedDisplayID = display.id
                        transientDisplayOrderIDs = displayOrder
                        lastReorderedTargetID = nil
                        return NSItemProvider(object: display.id as NSString)
                    } preview: {
                        displayDragPreview(display)
                    }
                    .dropDestination(
                        for: String.self
                    ) { items, _ in
                        defer { endDisplayDrag() }
                        return items.first != nil
                    } isTargeted: { targeted in
                        updateDropTarget(display.id, targeted: targeted)
                    }
                    .overlay {
                        if dropTargetDisplayID == display.id {
                            RoundedRectangle(
                                cornerRadius: 16,
                                style: .continuous
                            )
                            .strokeBorder(
                                TesseraeTheme.accent.opacity(0.8),
                                lineWidth: 2
                            )
                            .allowsHitTesting(false)
                        }
                    }
                    .accessibilityHint(
                        "Tap for details. Long press and drag to reorder."
                    )
                    .task(
                        id: display.previewRefreshID(
                            generation: model.displayPreviewGeneration
                        )
                    ) {
                        await model.loadDisplayPreview(display)
                    }
                }
            }
            .padding(16)
            .animation(
                .spring(
                    response: 0.24,
                    dampingFraction: 0.88
                ),
                value: displayOrder
            )
        }
        .overlay {
            if model.isRefreshing && model.displays.isEmpty {
                ProgressView("Loading displays…")
            } else if model.displays.isEmpty {
                ContentUnavailableView {
                    Label("No Displays", systemImage: "rectangle.slash")
                } description: {
                    Text("No displays were returned by this Tesserae server.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refreshDisplays() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .refreshable {
            await model.refreshDisplays()
        }
        .sheet(item: $selectedDisplay) { display in
            NavigationStack {
                DisplayDetailView(display: display)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(isPresented: $lineupsPresented) {
            LineupsView(isActive: isActive && lineupsPresented)
        }
        .task(id: shouldAutoRefresh) {
            guard shouldAutoRefresh else { return }

            await model.refreshDisplays(
                showErrors: false,
                saveSnapshot: false
            )
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard draggedDisplayID == nil else { continue }
                await model.refreshDisplays(
                    showErrors: false,
                    saveSnapshot: false
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TesseraeSettingsToolbarButton(openSettings: presentSettings)
            }
        }
        .tesseraeScreenBackground()
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private func displayDragPreview(
        _ display: DisplaySummary
    ) -> some View {
        ReorderDragPreview(title: display.name) {
            PhosphorIcon(
                name: display.canonicalIconName,
                size: 28,
                fallbackSystemName: display.previewSymbol
            )
        }
        .onDisappear {
            endDisplayDrag()
        }
    }

    private func updateDropTarget(
        _ targetID: String,
        targeted: Bool
    ) {
        guard targeted else {
            if dropTargetDisplayID == targetID {
                dropTargetDisplayID = nil
            }
            reorderTargetResetTask?.cancel()
            reorderTargetResetTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled, dropTargetDisplayID == nil else {
                    return
                }
                lastReorderedTargetID = nil
                reorderTargetResetTask = nil
            }
            return
        }

        reorderTargetResetTask?.cancel()
        reorderTargetResetTask = nil
        dropTargetDisplayID = targetID

        guard
            let sourceID = draggedDisplayID,
            sourceID != targetID,
            targetID != lastReorderedTargetID,
            var order = transientDisplayOrderIDs,
            let sourceIndex = order.firstIndex(of: sourceID),
            let targetIndex = order.firstIndex(of: targetID)
        else {
            return
        }

        order.remove(at: sourceIndex)
        order.insert(sourceID, at: min(targetIndex, order.count))
        guard order != transientDisplayOrderIDs else { return }

        lastReorderedTargetID = targetID
        transientDisplayOrderIDs = order
        hapticEvent.trigger(.rigidImpact)
    }

    private func endDisplayDrag() {
        reorderTargetResetTask?.cancel()
        if let sourceID = draggedDisplayID,
           let finalIndex = transientDisplayOrderIDs?.firstIndex(of: sourceID)
        {
            model.moveDisplay(sourceID, to: finalIndex)
        }
        draggedDisplayID = nil
        dropTargetDisplayID = nil
        transientDisplayOrderIDs = nil
        lastReorderedTargetID = nil
        reorderTargetResetTask = nil
    }
}

private struct DisplayCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let display: DisplaySummary
    let preview: PreviewImageState?
    private let previewCanvasSize = CGSize(width: 112, height: 118)

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    displayIdentityIcon

                    Text(display.name)
                        .font(.headline)
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .layoutPriority(1)
                }

                DisplayHardwareBadge(
                    presentation: display.hardwarePresentation
                )

                HStack(spacing: 12) {
                    metric(
                        "battery.75percent",
                        display.batteryPercent.map { "\($0)%" } ?? "—"
                    )
                    metric(
                        "wifi",
                        display.rssiDBM.map { "\($0) dBm" } ?? "—"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            panelPreview
        }
        .tesseraeCard()
    }

    private var displayIdentityIcon: some View {
        ZStack(alignment: .bottomTrailing) {
            PhosphorIcon(
                name: display.canonicalIconName,
                size: 19,
                fallbackSystemName: display.previewSymbol
            )

            Circle()
                .fill(display.freshnessColor)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(cardSurfaceColor, lineWidth: 1.5)
                }
                .offset(x: 2, y: 2)
        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.freshnessLabel)
    }

    private var cardSurfaceColor: Color {
        colorScheme == .dark
            ? Color(red: 24 / 255, green: 27 / 255, blue: 34 / 255)
            : .white
    }

    private var panelPreview: some View {
        let previewSize = display.panel.fittedPreviewSize(
            maxWidth: previewCanvasSize.width,
            maxHeight: previewCanvasSize.height
        )

        return ZStack {
            Color.clear

            ZStack(alignment: .topTrailing) {
                PreviewArtwork(
                    state: preview,
                    placeholderSystemName: display.previewSymbol,
                    placeholderLabel: "Display preview placeholder, \(display.panel.width) by \(display.panel.height), \(display.panel.orientation)",
                    imageLabel: "Last-served device preview for \(display.name)",
                    accessibilityIdentifier: "display-preview-\(display.id)",
                    placeholderDetail: "\(display.panel.width) × \(display.panel.height)"
                )

                if display.hasPendingRender == true {
                    PendingRenderGlyph()
                        .offset(x: 6, y: -6)
                        .transition(
                            .scale(scale: 0.75)
                                .combined(with: .opacity)
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Waiting for display refresh")
                        .accessibilityHint(
                            "The new frame will appear the next time this display wakes."
                        )
                        .accessibilityIdentifier(
                            "display-pending-indicator-\(display.id)"
                        )
                }
            }
            .frame(
                width: CGFloat(previewSize.width),
                height: CGFloat(previewSize.height)
            )
        }
        .frame(
            width: previewCanvasSize.width,
            height: previewCanvasSize.height
        )
        .animation(
            .easeInOut(duration: 0.2),
            value: display.hasPendingRender
        )
    }

    private func metric(_ symbol: String, _ value: String) -> some View {
        Label(value, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }

}

private struct PendingRenderGlyph: View {
    var body: some View {
        Image(systemName: "clock.arrow.circlepath")
            .font(.caption2.weight(.bold))
            .foregroundStyle(TesseraeTheme.ochre)
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(TesseraeTheme.ochre.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }
}

private struct DisplayDetailView: View {
    private enum ScreenPage: Hashable {
        case current
        case next
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedScreenPage: ScreenPage = .current
    @State private var hapticEvent = TesseraeHapticEvent()
    let display: DisplaySummary

    private var currentDisplay: DisplaySummary {
        model.displays.first(where: { $0.id == display.id }) ?? display
    }

    private var visibleScreenPage: ScreenPage {
        currentDisplay.pendingRender == nil ? .current : selectedScreenPage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                screenCarouselCard

                if model.supportsDeviceTimeline {
                    nextUpdateCard
                }

                detailCard(
                    "Connection & Power",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    detailRow("Status") {
                        Label(
                            currentDisplay.freshnessLabel,
                            systemImage: currentDisplay.freshnessSymbol
                        )
                        .foregroundStyle(currentDisplay.freshnessColor)
                    }

                    detailRow("Last Seen") {
                        if let lastSeenAt = currentDisplay.lastSeenAt {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(lastSeenAt, style: .relative)
                                Text(
                                    lastSeenAt,
                                    format: .dateTime
                                        .year()
                                        .month()
                                        .day()
                                        .hour()
                                        .minute()
                                )
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Not reported")
                        }
                    }

                    detailRow("Battery") {
                        Text(
                            currentDisplay.batteryPercent.map { "\($0)%" }
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Signal") {
                        Text(
                            currentDisplay.rssiDBM.map { "\($0) dBm" }
                                ?? String(localized: "Not reported")
                        )
                    }
                }

                detailCard("Hardware", systemImage: "cpu") {
                    detailRow("Manufacturer") {
                        Text(
                            currentDisplay.hardwarePresentation.brand?.displayName
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Model") {
                        Text(
                            currentDisplay.hardwarePresentation.modelName
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Firmware") {
                        Text(
                            currentDisplay.firmwareVersion
                                ?? String(localized: "Not reported")
                        )
                    }

                    detailRow("Device Type") {
                        Text(currentDisplay.kind)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }

                    detailRow("Device ID") {
                        Text(currentDisplay.id)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                detailCard("Panel", systemImage: "rectangle.inset.filled") {
                    detailRow("Resolution") {
                        Text(
                            "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
                        )
                        .monospacedDigit()
                    }

                    detailRow("Orientation") {
                        Text(currentDisplay.orientationLabel)
                    }

                    detailRow("Colour Gamut") {
                        Text(currentDisplay.gamutLabel)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(currentDisplay.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") {
                    dismiss()
                }
            }
        }
        .task(
            id: currentDisplay.previewRefreshID(
                generation: model.displayPreviewGeneration
            )
        ) {
            await model.loadDisplayPreview(currentDisplay)
        }
        .task(id: currentDisplay.pendingRender?.revision) {
            await model.loadPendingDisplayPreview(currentDisplay)
        }
        .task(id: "\(currentDisplay.id)-\(model.supportsDeviceTimeline)") {
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
        }
        .task(id: nextUpcomingEvent?.id) {
            guard let scheduledAt = nextUpcomingEvent?.scheduledAt else { return }
            let delay = scheduledAt.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay + 1))
            }
            guard !Task.isCancelled else { return }
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
        }
        .refreshable {
            await model.refreshDisplays(showErrors: false)
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            }
        }
        .onChange(of: currentDisplay.pendingRender?.revision) { _, revision in
            if revision == nil {
                selectedScreenPage = .current
            }
        }
        .onChange(of: selectedScreenPage) { oldValue, newValue in
            guard
                oldValue != newValue,
                currentDisplay.pendingRender != nil
            else {
                return
            }
            hapticEvent.trigger(.selection)
        }
        .tesseraeScreenBackground()
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private var upcomingResponse: DeviceUpcomingResponse? {
        model.deviceUpcomingResponses[currentDisplay.id]
    }

    private var nextUpcomingEvent: DeviceUpcomingEvent? {
        upcomingResponse?.events.first
    }

    @ViewBuilder
    private var nextUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Next Update", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if let event = nextUpcomingEvent,
               let response = upcomingResponse
            {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    nextUpdateContent(
                        event: event,
                        response: response,
                        now: context.date
                    )
                }
            } else if model.loadingDeviceTimelineIDs.contains(currentDisplay.id),
                      upcomingResponse == nil
            {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading scheduled updates…")
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 48)
            } else if let error = model.deviceTimelineErrors[currentDisplay.id] {
                HStack(alignment: .center, spacing: 12) {
                    Text(error)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Button("Retry") {
                        Task {
                            await model.refreshDeviceUpcoming(
                                displayID: currentDisplay.id,
                                showErrors: true
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                }
            } else if let response = upcomingResponse {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No scheduled update")
                        .font(.subheadline.weight(.semibold))
                    Text("Nothing projected through \(response.throughAt.formatted(date: .abbreviated, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tesseraeCard()
        .accessibilityIdentifier("display-next-update-\(currentDisplay.id)")
    }

    private func nextUpdateContent(
        event: DeviceUpcomingEvent,
        response: DeviceUpcomingResponse,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(upcomingTarget(event))
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(upcomingReason(event))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(event.scheduledAt, style: .relative)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(upcomingAccent(event.certainty))
                    Text(
                        event.scheduledAt,
                        format: .dateTime.weekday(.abbreviated).hour().minute()
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let start = response.currentFrameAt,
               start < event.scheduledAt
            {
                ProgressView(
                    value: min(
                        max(now.timeIntervalSince(start), 0),
                        event.scheduledAt.timeIntervalSince(start)
                    ),
                    total: event.scheduledAt.timeIntervalSince(start)
                )
                .tint(upcomingAccent(event.certainty))
                .accessibilityLabel("Time until next update")
            }

            HStack(spacing: 8) {
                Image(systemName: upcomingSymbol(event))
                Text(upcomingEffect(event))
                if event.certainty != .scheduled {
                    Text("·")
                    Text(upcomingCertainty(event.certainty))
                }
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
    }

    private func upcomingTarget(_ event: DeviceUpcomingEvent) -> String {
        event.dashboardName
            ?? event.lineupName
            ?? String(localized: "Lineup update")
    }

    private func upcomingReason(_ event: DeviceUpcomingEvent) -> String {
        switch (event.cause, event.effect) {
        case (.interval, .refreshScreen):
            String(localized: "Keep Fresh")
        case (.cycle, .changeScreen):
            String(localized: "Lineup rotation")
        case (.cycle, .refreshScreen):
            String(localized: "Lineup refresh")
        case (.daily, .changeScreen):
            String(localized: "Daily schedule")
        case (.daily, .refreshScreen):
            String(localized: "Daily refresh")
        case (.homeReturn, _):
            String(localized: "Home Return")
        case (.dashboardRefresh, _):
            String(localized: "Dashboard refresh")
        case (.widgetRefresh, _):
            String(localized: "Widget refresh")
        case (.interval, .changeScreen):
            String(localized: "Interval schedule")
        }
    }

    private func upcomingEffect(_ event: DeviceUpcomingEvent) -> String {
        switch event.effect {
        case .changeScreen:
            String(localized: "Changes the screen")
        case .refreshScreen:
            String(localized: "Refreshes the current screen")
        }
    }

    private func upcomingCertainty(_ certainty: DeviceUpcomingCertainty) -> String {
        switch certainty {
        case .scheduled:
            String(localized: "Scheduled")
        case .conditional:
            String(localized: "Conditional")
        case .estimated:
            String(localized: "Estimated")
        }
    }

    private func upcomingAccent(_ certainty: DeviceUpcomingCertainty) -> Color {
        certainty == .scheduled ? TesseraeTheme.accent : TesseraeTheme.ochre
    }

    private func upcomingSymbol(_ event: DeviceUpcomingEvent) -> String {
        switch event.effect {
        case .changeScreen:
            "arrow.left.arrow.right.square"
        case .refreshScreen:
            "arrow.clockwise"
        }
    }

    private var screenCarouselCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            screenPageHeader

            TabView(selection: $selectedScreenPage) {
                currentScreenPreview
                    .tag(ScreenPage.current)

                if currentDisplay.pendingRender != nil {
                    nextScreenPreview
                        .tag(ScreenPage.next)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: 380)
            .accessibilityIdentifier(
                "display-screen-carousel-\(currentDisplay.id)"
            )

            if currentDisplay.pendingRender != nil {
                screenPageIndicator
            }

            if currentDisplay.hasPendingRender == true,
               currentDisplay.pendingRender == nil
            {
                pendingRefreshExplanation
                    .transition(
                        .move(edge: .top)
                            .combined(with: .opacity)
                    )
            }
        }
        .tesseraeCard()
        .animation(
            .easeInOut(duration: 0.22),
            value: visibleScreenPage
        )
    }

    private var screenPageHeader: some View {
        ZStack(alignment: .leading) {
            Label("Current Screen", systemImage: "display")
                .font(.headline)
                .opacity(visibleScreenPage == .current ? 1 : 0)
                .accessibilityHidden(visibleScreenPage != .current)

            HStack(spacing: 10) {
                Label("Next Screen", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(TesseraeTheme.ochre)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .layoutPriority(1)

                Spacer(minLength: 8)

                if let renderedAt = currentDisplay.pendingRender?.renderedAt {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("Rendered")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(renderedAt, style: .relative)
                            .font(.caption.weight(.medium))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity)
            .opacity(visibleScreenPage == .next ? 1 : 0)
            .accessibilityHidden(visibleScreenPage != .next)
        }
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: visibleScreenPage)
    }

    private var currentScreenPreview: some View {
        PreviewArtwork(
            state: model.displayPreviews[currentDisplay.id],
            placeholderSystemName: currentDisplay.previewSymbol,
            placeholderLabel: "Display preview placeholder, \(currentDisplay.panel.width) by \(currentDisplay.panel.height), \(currentDisplay.panel.orientation)",
            imageLabel: "Last-served device preview for \(currentDisplay.name)",
            accessibilityIdentifier: "display-detail-preview-\(currentDisplay.id)",
            placeholderDetail: "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
        )
    }

    private var nextScreenPreview: some View {
        PreviewArtwork(
            state: model.pendingDisplayPreview(for: currentDisplay),
            placeholderSystemName: currentDisplay.previewSymbol,
            placeholderLabel: "Pending display preview, \(currentDisplay.panel.width) by \(currentDisplay.panel.height), \(currentDisplay.panel.orientation)",
            imageLabel: "Next device preview for \(currentDisplay.name)",
            accessibilityIdentifier: "display-detail-pending-preview-\(currentDisplay.id)",
            placeholderDetail: "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
        )
    }

    private var screenPageIndicator: some View {
        HStack(spacing: 7) {
            screenPageIndicatorButton(
                page: .current,
                label: "Current Screen"
            )
            screenPageIndicatorButton(
                page: .next,
                label: "Next Screen"
            )
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier(
            "display-screen-page-indicator-\(currentDisplay.id)"
        )
    }

    private func screenPageIndicatorButton(
        page: ScreenPage,
        label: LocalizedStringKey
    ) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedScreenPage = page
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(
                        visibleScreenPage == page
                            ? TesseraeTheme.accent
                            : Color.secondary.opacity(0.28)
                    )
                    .frame(
                        width: visibleScreenPage == page ? 20 : 7,
                        height: 7
                    )
                    .animation(
                        .easeInOut(duration: 0.2),
                        value: visibleScreenPage
                    )
            }
            .frame(width: 28, height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private var pendingRefreshExplanation: some View {
        HStack(alignment: .top, spacing: 10) {
            PendingRenderGlyph()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for display refresh")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.ochre)

                Text(
                    "The new frame will appear the next time this display wakes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            TesseraeTheme.ochre.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "display-pending-status-\(currentDisplay.id)"
        )
    }

    private func detailCard<Content: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            content()
        }
        .tesseraeCard()
    }

    private func detailRow<Value: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            value()
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }
}

private extension DisplaySummary {
    func previewRefreshID(generation: Int) -> DisplayPreviewRefreshID {
        DisplayPreviewRefreshID(
            generation: generation,
            hasPendingRender: hasPendingRender,
            lastSeenAt: lastSeenAt
        )
    }

    var freshnessLabel: String {
        switch freshness {
        case .fresh: String(localized: "Recently seen")
        case .stale: String(localized: "Last seen earlier")
        case .unknown: String(localized: "Unknown")
        }
    }

    var freshnessSymbol: String {
        switch freshness {
        case .fresh: "checkmark.circle.fill"
        case .stale: "clock.fill"
        case .unknown: "questionmark.circle.fill"
        }
    }

    var freshnessColor: Color {
        switch freshness {
        case .fresh: TesseraeTheme.accent
        case .stale: TesseraeTheme.ochre
        case .unknown: .secondary
        }
    }

    var previewSymbol: String {
        panel.height > panel.width
            ? "rectangle.portrait.inset.filled"
            : "rectangle.inset.filled"
    }

    var panelAspectRatio: CGFloat {
        guard panel.height > 0 else { return 1 }
        return CGFloat(panel.width) / CGFloat(panel.height)
    }

    var orientationLabel: String {
        switch panel.orientation.lowercased() {
        case "portrait":
            String(localized: "Portrait")
        case "landscape":
            String(localized: "Landscape")
        default:
            panel.orientation.localizedCapitalized
        }
    }

    var gamutLabel: String {
        switch panel.gamut.lowercased() {
        case "spectra_6", "waveshare_e6", "e6":
            String(localized: "Spectra 6 · 6-color")
        default:
            panel.gamut
                .replacingOccurrences(of: "_", with: " ")
                .localizedCapitalized
        }
    }
}
