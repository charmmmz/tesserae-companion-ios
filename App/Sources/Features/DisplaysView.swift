import SwiftUI
import TesseraeKit
import UIKit
import Observation

private struct DisplayPreviewRefreshID: Hashable {
    let generation: Int
    let hasPendingRender: Bool?
    let lastSeenAt: Date?
}

struct DisplaysView: View {
    @Environment(NearbyDeviceManager.self) private var nearby
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var draggedDisplayID: String?
    @State private var reorderMotion = DisplayReorderMotion()
    @State private var transientDisplayOrderIDs: [String]?
    @State private var displayCardSizes: [String: CGSize] = [:]
    @State private var dragStartFrames: [String: CGRect] = [:]
    @State private var dragStartOrderIDs: [String] = []
    @State private var lastReorderedIndex: Int?
    @State private var selectedDisplayID: String?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar
    @State private var lineupsPresented = false
    @State private var hapticEvent = TesseraeHapticEvent()
    private let displayCardSpacing: CGFloat = 14

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && !lineupsPresented && scenePhase == .active
    }

    private var usesCompactOfflineHeader: Bool {
        model.connectionHealth == .restoring || model.connectionHealth == .offline
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
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            displayList
                .tesseraeRootPageChrome()
                .navigationTitle("Displays")
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 440)
        } detail: {
            NavigationStack {
                if let display = model.displays.first(where: { $0.id == selectedDisplayID }) {
                    DisplayDetailView(display: display)
                        .id(display.id)
                } else {
                    ContentUnavailableView("Select a Display", systemImage: "display")
                        .tesseraeScreenBackground()
                }
            }
            .lineupDestinations()
        }
        .navigationSplitViewStyle(.balanced)
        .tesseraeScreenBackground()
    }

    @ViewBuilder
    private var displayList: some View {
        let displays = displayedDisplays
        let displayOrder = displays.map(\.id)

        ScrollView {
            LazyVStack(spacing: displayCardSpacing) {
                ForEach(displays) { display in
                    displayRow(display, displayOrder: displayOrder)
                }
            }
            .padding(16)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: displayOrder
            )
        }
        .coordinateSpace(name: "displays-scroll")
        .scrollDisabled(draggedDisplayID != nil)
        .overlay {
            GeometryReader { _ in
                if
                    let draggedDisplayID,
                    let display = model.displays.first(
                        where: { $0.id == draggedDisplayID }
                    ),
                    let origin = dragStartFrames[draggedDisplayID]
                {
                    LiftedDisplayCard(
                        display: display,
                        preview: model.displayPreviews[display.id],
                        origin: origin,
                        motion: reorderMotion
                    )
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
            }
        }
        .overlay {
            if model.displays.isEmpty && model.isRefreshing {
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
                    .tint(TesseraeTheme.accentFill)
                    .foregroundStyle(.white)
                }
            }
        }
        .refreshable {
            await model.refreshDisplays()
        }
        .navigationDestination(isPresented: $lineupsPresented) {
            LineupsView(isActive: isActive && lineupsPresented)
                .lineupDestinations()
                .toolbar {
                    if horizontalSizeClass == .regular {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Displays", systemImage: "chevron.backward") {
                                lineupsPresented = false
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityIdentifier("lineups-back-to-displays")
                        }
                    }
                }
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
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            cancelDisplayDrag()
        }
        .onDisappear { cancelDisplayDrag() }
        .toolbar {
            TesseraeRootToolbar(
                showsGlobalActions: horizontalSizeClass == .compact || selectedDisplayID == nil
            ) {
                if model.supportsLineups {
                    manageLineupsButton
                }
            }
        }
        .tesseraeScreenBackground()
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private var manageLineupsButton: some View {
        Button {
            lineupsPresented = true
        } label: {
            Label {
                Text("Manage Lineups")
            } icon: {
                PhosphorIcon(name: "monitor-play", size: TesseraeActionMetrics.iconSize)
            }
        }
        .accessibilityLabel("Manage Lineups")
        .accessibilityIdentifier("manage-lineups")
        .accessibilityHint("Opens Lineups and controls.")
    }

    private func displayCardButton(
        _ display: DisplaySummary,
        displayOrder: [String]
    ) -> some View {
        Button {
            lineupsPresented = false
            selectedDisplayID = display.id
            preferredColumn = .detail
        } label: {
            DisplayCard(
                display: display,
                preview: model.displayPreviews[display.id]
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("display-card-\(display.id)")
        .accessibilityAddTraits(.isButton)
        // Reordering needs size only; the recognizer supplies the current origin.
        // Tracking scroll-relative frames here invalidated the list on every scroll tick.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            displayCardSizes[display.id] = size
        }
        .opacity(draggedDisplayID == display.id ? 0 : 1)
        .overlay {
            if draggedDisplayID == display.id {
                RoundedRectangle(
                    cornerRadius: 16,
                    style: .continuous
                )
                .fill(TesseraeTheme.accent.opacity(0.07))
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 16,
                        style: .continuous
                    )
                    .stroke(
                        TesseraeTheme.accent.opacity(0.4),
                        style: StrokeStyle(
                            lineWidth: 1.5,
                            dash: [6, 5]
                        )
                    )
                }
                .allowsHitTesting(false)
            }
        }
        .gesture(
            DisplayReorderLongPressGesture(
                onBegan: { currentOrigin in
                    beginDisplayDrag(
                        displayID: display.id,
                        displayOrder: displayOrder,
                        currentOrigin: currentOrigin
                    )
                },
                onChanged: { translation in
                    guard draggedDisplayID == display.id else {
                        return
                    }
                    reorderMotion.translation = translation
                    reorderMotion.didMove = reorderMotion.didMove
                        || abs(translation.height) > 2
                    updateLiveReorder(translation: translation)
                },
                onEnded: endDisplayDrag
            )
        )
    }

    private func localState(_ display: DisplaySummary) -> DisplayBluetoothPresentation {
        nearby.displayRecords.presentation(for: display, serverID: model.activeInstance?.id)
    }

    private func displayRow(
        _ display: DisplaySummary,
        displayOrder: [String]
    ) -> some View {
        displayCardButton(display, displayOrder: displayOrder)
            .accessibilityHint(
                "Tap for details. Long press and drag to reorder."
            )
            .accessibilityLabel(Text("\(display.name), \(localState(display).isBluetooth ? String(localized: "Bluetooth Mode") : display.freshnessLabel)"))
            .accessibilityValue(
                Text("Display \((displayOrder.firstIndex(of: display.id) ?? 0) + 1) of \(displayOrder.count)")
            )
            .accessibilityCustomContent(
                "Hardware",
                Text([display.hardwarePresentation.brand?.displayName,
                      display.hardwarePresentation.modelName].compactMap { $0 }.joined(separator: ", "))
            )
            .accessibilityCustomContent("Battery", Text(localState(display).batteryText))
            .accessibilityCustomContent("Connection", Text(localState(display).isBluetooth
                ? String(localized: "Bluetooth") : "Wi-Fi"))
            .accessibilityCustomContent(
                "Status",
                Text(localState(display).isBluetooth ? String(localized: "Bluetooth Mode") : display.hasPendingRender == true
                     ? String(localized: "Waiting for display refresh")
                     : display.freshnessLabel)
            )
            .accessibilityActions {
                if let index = displayOrder.firstIndex(of: display.id) {
                    if index > 0 {
                        Button("Move Up") {
                            moveDisplayForAccessibility(display, to: index - 1)
                        }
                    }
                    if index < displayOrder.count - 1 {
                        Button("Move Down") {
                            moveDisplayForAccessibility(display, to: index + 1)
                        }
                    }
                }
            }
            .task(
                id: display.previewRefreshID(
                    generation: model.displayPreviewGeneration
                )
            ) {
                await model.loadDisplayPreview(display)
            }
    }

    private func moveDisplayForAccessibility(_ display: DisplaySummary, to index: Int) {
        guard draggedDisplayID == nil else { return }
        model.moveDisplay(display.id, to: index)
        hapticEvent.trigger(.selection)
        UIAccessibility.post(
            notification: .announcement,
            argument: String(localized: "\(display.name), display \(index + 1) of \(model.displays.count)")
        )
    }

    private func beginDisplayDrag(
        displayID: String,
        displayOrder: [String],
        currentOrigin: CGPoint
    ) {
        guard
            draggedDisplayID == nil,
            let sourceIndex = displayOrder.firstIndex(of: displayID),
            let sourceSize = displayCardSizes[displayID]
                ?? displayCardSizes.values.first
        else { return }

        // Build ordered slots around the exact origin reported by the recognizer.
        let slotStride = sourceSize.height + displayCardSpacing
        let correctedFrames = Dictionary(
            uniqueKeysWithValues: displayOrder.enumerated().map { index, id in
                let offset = CGFloat(index - sourceIndex) * slotStride
                return (
                    id,
                    CGRect(
                        x: currentOrigin.x,
                        y: currentOrigin.y + offset,
                        width: sourceSize.width,
                        height: sourceSize.height
                    )
                )
            }
        )

        draggedDisplayID = displayID
        dragStartFrames = correctedFrames
        dragStartOrderIDs = displayOrder
        transientDisplayOrderIDs = displayOrder
        reorderMotion.reset()
        lastReorderedIndex = sourceIndex
        hapticEvent.trigger(.lightImpact)
    }

    private func updateLiveReorder(translation: CGSize) {
        guard
            let sourceID = draggedDisplayID,
            let sourceFrame = dragStartFrames[sourceID],
            let sourceIndex = dragStartOrderIDs.firstIndex(of: sourceID)
        else {
            return
        }

        let draggedCenterY = sourceFrame.midY + translation.height
        let slots = dragStartOrderIDs.enumerated().compactMap {
            index, id -> (index: Int, frame: CGRect)? in
            guard let frame = dragStartFrames[id] else { return nil }
            return (index, frame)
        }

        guard let targetIndex = slots.min(by: {
                abs($0.frame.midY - draggedCenterY)
                    < abs($1.frame.midY - draggedCenterY)
            })?.index
        else {
            return
        }

        guard targetIndex != lastReorderedIndex else { return }

        if
            let lastReorderedIndex,
            let lastFrame = dragStartFrames[dragStartOrderIDs[lastReorderedIndex]],
            let targetFrame = dragStartFrames[dragStartOrderIDs[targetIndex]]
        {
            let midpoint = (lastFrame.midY + targetFrame.midY) / 2
            let hysteresis = min(
                18,
                abs(lastFrame.midY - targetFrame.midY) * 0.1
            )
            if targetIndex < lastReorderedIndex {
                guard draggedCenterY < midpoint - hysteresis else { return }
            } else {
                guard draggedCenterY > midpoint + hysteresis else { return }
            }
        }

        var order = dragStartOrderIDs
        order.remove(at: sourceIndex)
        order.insert(sourceID, at: min(targetIndex, order.count))
        guard order != transientDisplayOrderIDs else { return }

        lastReorderedIndex = targetIndex
        transientDisplayOrderIDs = order
        hapticEvent.trigger(.selection)
    }

    private func endDisplayDrag() {
        if let sourceID = draggedDisplayID,
           let finalIndex = transientDisplayOrderIDs?.firstIndex(of: sourceID)
        {
            model.moveDisplay(sourceID, to: finalIndex)
            if reorderMotion.didMove {
                hapticEvent.trigger(.rigidImpact)
            }
        }
        cancelDisplayDrag()
    }

    private func cancelDisplayDrag() {
        draggedDisplayID = nil
        reorderMotion.reset()
        transientDisplayOrderIDs = nil
        dragStartFrames = [:]
        dragStartOrderIDs = []
        lastReorderedIndex = nil
    }
}

@Observable
private final class DisplayReorderMotion {
    var translation: CGSize = .zero
    var didMove = false

    func reset() {
        translation = .zero
        didMove = false
    }
}

private struct LiftedDisplayCard: View {
    let display: DisplaySummary
    let preview: PreviewImageState?
    let origin: CGRect
    let motion: DisplayReorderMotion

    var body: some View {
        DisplayCard(display: display, preview: preview)
            .frame(width: origin.width, height: origin.height)
            .drawingGroup()
            .scaleEffect(1.015)
            .shadow(
                color: .black.opacity(0.18),
                radius: 14,
                y: 7
            )
            .position(
                x: origin.midX,
                y: origin.midY + motion.translation.height
            )
    }
}

private struct DisplayReorderLongPressGesture: UIGestureRecognizerRepresentable {
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var startLocation: CGPoint?
        var didBegin = false

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // A card tap can open details only if its long press failed.
            otherGestureRecognizer is UITapGestureRecognizer
        }
    }

    let onBegan: (CGPoint) -> Void
    let onChanged: (CGSize) -> Void
    let onEnded: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(
        context: Context
    ) -> UILongPressGestureRecognizer {
        let recognizer = UILongPressGestureRecognizer()
        recognizer.minimumPressDuration = 0.35
        recognizer.allowableMovement = 10
        // Once a long press starts reordering, its release must not activate
        // the card's details button. Short taps still pass through normally.
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func handleUIGestureRecognizerAction(
        _ recognizer: UILongPressGestureRecognizer,
        context: Context
    ) {
        let location = context.converter.location(
            in: .named("displays-scroll")
        )
        let localLocation = context.converter.localLocation

        switch recognizer.state {
        case .began:
            context.coordinator.startLocation = location
            context.coordinator.didBegin = true
            onBegan(
                CGPoint(
                    x: location.x - localLocation.x,
                    y: location.y - localLocation.y
                )
            )
        case .changed:
            guard let startLocation = context.coordinator.startLocation else {
                return
            }
            onChanged(
                CGSize(
                    width: location.x - startLocation.x,
                    height: location.y - startLocation.y
                )
            )
        case .ended, .cancelled:
            guard context.coordinator.didBegin else { return }
            context.coordinator.startLocation = nil
            context.coordinator.didBegin = false
            onEnded()
        default:
            break
        }
    }
}

private struct DisplayCard: View {
    @Environment(AppModel.self) private var model
    @Environment(NearbyDeviceManager.self) private var nearby
    private var local: DisplayBluetoothPresentation {
        nearby.displayRecords.presentation(for: display, serverID: model.activeInstance?.id)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let display: DisplaySummary
    let preview: PreviewImageState?
    private var previewCanvasSize: CGSize {
        dynamicTypeSize.isAccessibilitySize
            ? CGSize(width: 224, height: 236)
            : CGSize(width: 112, height: 118)
    }

    private var cardLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
    }

    var body: some View {
        cardLayout {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    displayIdentityIcon

                    Text(display.name)
                        .font(.headline)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }

                DisplayHardwareBadge(
                    presentation: display.hardwarePresentation
                )

                (dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                    : AnyLayout(HStackLayout(spacing: 12))) {
                    metric(
                        "battery.75percent",
                        local.batteryText
                    )
                    if local.isBluetooth {
                        BluetoothModeLabel(compact: true)
                    } else {
                        metric("wifi", "Wi-Fi")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("display-metrics-\(display.id)")
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
                .fill(local.isBluetooth ? TesseraeTheme.info : display.freshnessColor)
                .frame(width: 8, height: 8)
                .overlay {
                    Circle()
                        .stroke(cardSurfaceColor, lineWidth: 1.5)
                }
                .offset(x: 2, y: 2)
        }
        .frame(width: 24, height: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(local.isBluetooth ? String(localized: "Bluetooth Mode") : display.freshnessLabel)
    }

    private var cardSurfaceColor: Color {
        TesseraeTheme.surface
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
                    state: local.preview ?? preview,
                    placeholderSystemName: display.previewSymbol,
                    placeholderLabel: "Display preview placeholder, \(display.panel.width) by \(display.panel.height), \(display.panel.orientation)",
                    imageLabel: local.usesLocalPreview ? String(localized: "Last Bluetooth Send") : String(localized: "Server preview for \(display.name)"),
                    accessibilityIdentifier: "display-preview-\(display.id)",
                    placeholderDetail: "\(display.panel.width) × \(display.panel.height)"
                )

                if display.hasPendingRender == true && !local.isBluetooth && !local.usesLocalPreview {
                    PendingRenderGlyph()
                        .offset(x: 6, y: -6)
                        .transition(
                            .scale(scale: 0.75)
                                .combined(with: .opacity)
                        )
                        .accessibilityElement()
                        .accessibilityLabel("Waiting for display refresh")
                        .accessibilityHint(
                            "A frame is queued. Device collection and screen appearance are not confirmed."
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
            reduceMotion ? nil : .easeInOut(duration: 0.2),
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
            .foregroundStyle(TesseraeTheme.warning)
            .frame(width: 26, height: 26)
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(TesseraeTheme.warning.opacity(0.45), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
    }
}

private struct LineupDestinationModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: LineupRoute.self) { route in
            LineupRouteDestination(route: route)
        }
    }
}

private struct LineupRouteDestination: View {
    @Environment(AppModel.self) private var model
    let route: LineupRoute

    var body: some View {
        switch route {
        case let .lineup(id, displayID):
            LineupDetailView(lineupID: id, originatingDisplayID: displayID)
        case let .display(id):
            if let display = model.displays.first(where: { $0.id == id }) {
                DisplayDetailView(display: display)
            } else {
                ContentUnavailableView {
                    Label("Display Unavailable", systemImage: "display")
                } description: {
                    Text("This display is no longer returned by the server.")
                } actions: {
                    Button("Refresh") { Task { await model.refreshDisplays() } }
                }
                .tesseraeScreenBackground()
            }
        }
    }
}

extension View {
    func lineupDestinations() -> some View { modifier(LineupDestinationModifier()) }
}

private struct PlannedDashboardThumbnail: View {
    @Environment(AppModel.self) private var model
    let dashboardID: String
    let display: DisplaySummary

    var body: some View {
        PreviewArtwork(
            state: model.dashboardPreview(id: dashboardID, deviceID: display.id),
            placeholderSystemName: "rectangle.grid.2x2",
            placeholderLabel: "Planned dashboard preview",
            imageLabel: String(localized: "Planned dashboard preview"),
            accessibilityIdentifier: "display-planned-thumbnail-\(display.id)"
        )
        .aspectRatio(display.panelAspectRatio, contentMode: .fit)
        .frame(width: 60).frame(maxHeight: 90)
        .task(id: "\(dashboardID)|\(display.id)|\(model.previewGeneration)") {
            await model.loadDashboardPreview(id: dashboardID, deviceID: display.id)
        }
    }
}

private enum DisplayEvidencePreview: Identifiable {
    case server
    case queued(String)
    case planned(PlannedDisplayEvent)

    var id: String {
        switch self {
        case .server: "server"
        case let .queued(revision): "queued|\(revision)"
        case let .planned(event): "planned|\(event.id)"
        }
    }
}

struct DisplayDetailView: View {
    @Environment(NearbyDeviceManager.self) private var nearby
    private var local: DisplayBluetoothPresentation {
        nearby.displayRecords.presentation(for: currentDisplay, serverID: model.activeInstance?.id)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var hapticEvent = TesseraeHapticEvent()
    @State private var planNow = Date()
    private enum ScreenPage: Hashable { case recent, queued }

    @State private var selectedScreenPage: ScreenPage = .recent
    @State private var selectedPreview: DisplayEvidencePreview?
    @State private var laterExpanded = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let display: DisplaySummary

    private var currentDisplay: DisplaySummary {
        model.displays.first(where: { $0.id == display.id }) ?? display
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                connectionStrip
                if serverTimezoneDiffers(displayTimezone, at: displayedDates) {
                    Text("Times use \(displayTimezone.identifier)")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("display-timezone-note")
                }
                screenCarouselCard
                planCard
                displayLineupsCard
                DisplayDeviceDetails(display: currentDisplay, local: local, timezoneID: displayTimezone.identifier)
            }
            .frame(maxWidth: 720)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(currentDisplay.name)
        .tesseraeRootPageChrome()
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            TesseraeRootToolbar {
                EmptyView()
            }
        }
        .task(
            id: currentDisplay.previewRefreshID(
                generation: model.displayPreviewGeneration
            )
        ) {
            await model.loadDisplayPreview(currentDisplay)
        }
        .task(id: "\(model.connectionRevision)|\(model.supportsLineups)") {
            await model.refreshLineups(showErrors: false, saveSnapshot: false)
        }
        .task(id: currentDisplay.pendingRender?.revision) {
            await model.loadPendingDisplayPreview(currentDisplay)
        }
        .task(id: "\(currentDisplay.id)|\(model.supportsDeviceTimeline)|\(model.connectionRevision)") {
            guard model.supportsDeviceTimeline, !local.isBluetooth else { return }
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            while !Task.isCancelled {
                planNow = Date()
                let deadlines = [plan.next?.event.scheduledAt, plan.response?.throughAt].compactMap { $0 }
                let delay = deadlines.map { $0.timeIntervalSinceNow + 1 }.filter { $0 > 0 }.min() ?? 15
                do { try await Task.sleep(for: .seconds(min(delay, 60))) } catch { return }
                guard !Task.isCancelled else { return }
                planNow = Date()
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            }
        }
        .onChange(of: screenPages, initial: true) { _, pages in
            if !pages.contains(selectedScreenPage) { selectedScreenPage = .recent }
        }
        .onChange(of: currentDisplay.id) { _, _ in
            selectedScreenPage = .recent
        }
        .onChange(of: currentDisplay.lastSeenAt) { _, _ in
            Task {
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            }
        }
        .refreshable {
            await model.refreshDisplays(showErrors: false)
            guard !Task.isCancelled else { return }
            await model.refreshLineups(showErrors: false, saveSnapshot: false)
            guard !Task.isCancelled else { return }
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            }
        }
        .sheet(item: $selectedPreview) { preview in
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PreviewArtwork(
                            state: evidencePreviewState(preview),
                            placeholderSystemName: currentDisplay.previewSymbol,
                            placeholderLabel: evidencePreviewTitle(preview),
                            imageLabel: evidencePreviewTitle(preview),
                            accessibilityIdentifier: "display-evidence-preview-sheet"
                        )
                        .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
                        evidencePreviewExplanation(preview)
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 720)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle(evidencePreviewTitle(preview))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { selectedPreview = nil }
                            .labelStyle(.iconOnly)
                    }
                }
                .tesseraeScreenBackground()
            }
        }
        .tesseraeScreenBackground()
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private func evidencePreviewState(_ preview: DisplayEvidencePreview) -> PreviewImageState? {
        switch preview {
        case .server: local.preview ?? model.displayPreviews[currentDisplay.id]
        case let .queued(revision): currentDisplay.pendingRender?.revision == revision ? model.pendingDisplayPreview(for: currentDisplay) : nil
        case let .planned(event): event.event.dashboardID.flatMap { model.dashboardPreview(id: $0, deviceID: currentDisplay.id) }
        }
    }

    private func evidencePreviewTitle(_ preview: DisplayEvidencePreview) -> String {
        switch preview {
        case .server: previewTitle
        case .queued: String(localized: "Queued frame")
        case .planned: String(localized: "Planned dashboard preview")
        }
    }

    private var plan: DisplayPlanProjection {
        displayPlanProjections(
            deviceIDs: [currentDisplay.id], displays: model.displays,
            supported: model.supportsDeviceTimeline, responses: model.deviceUpcomingResponses,
            refreshing: model.loadingDeviceTimelineIDs, errors: model.deviceTimelineErrors, now: planNow
        )[0]
    }

    private var displayTimezone: TimeZone {
        effectiveServerTimezone(model.activeInstance?.timezone, fallbackID: plan.response?.timezone)
    }

    private var displayedDates: [Date] {
        [planNow, local.lastSeenAt(fallback: currentDisplay.lastSeenAt),
         local.usesLocalPreview ? local.record?.photoReceivedAt : plan.response?.currentFrameAt,
         local.usesLocalPreview || local.isBluetooth ? nil : currentDisplay.pendingRender?.renderedAt].compactMap { $0 }
            + (local.isBluetooth ? [] : plan.futureEvents.map(\.event.scheduledAt))
    }

    private var previewTitle: String {
        local.usesLocalPreview ? String(localized: "Last Bluetooth Send") : String(localized: "Server preview")
    }

    private var evidenceLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 16))
    }

    private var connectionStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { connectionMetrics }
            VStack(alignment: .leading, spacing: 6) { connectionMetrics }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("display-connection-summary")
    }

    @ViewBuilder
    private var connectionMetrics: some View {
        if local.isBluetooth {
            BluetoothModeLabel()
        } else {
            Label("Wi-Fi", systemImage: "wifi")
                .accessibilityValue(currentDisplay.freshnessLabel)
                .foregroundStyle(currentDisplay.freshnessColor)
        }
        Label(local.batteryText, systemImage: "battery.50percent")
            .accessibilityLabel(String(localized: "Battery") + " · " + local.batteryText)
        if let seen = local.lastSeenAt(fallback: currentDisplay.lastSeenAt) {
            Text("Seen \(compactProjectionDateText(seen, timezone: displayTimezone.identifier))")
        } else {
            Text("Seen · Not reported")
        }
    }

    @ViewBuilder
    private func evidencePreviewExplanation(_ preview: DisplayEvidencePreview) -> some View {
        switch preview {
        case .server:
            Text(local.usesLocalPreview ? "Saved from a local Bluetooth Send." : "The latest preview available from the server.")
            if local.usesLocalPreview, let date = local.record?.photoReceivedAt {
                Text(String(localized: "Local Send record · \(projectionDateText(date, timezone: displayTimezone.identifier))"))
            } else if let date = plan.response?.currentFrameAt {
                Text(String(localized: "Last served or published · \(projectionDateText(date, timezone: displayTimezone.identifier))"))
            }
            Text("Screen appearance is not confirmed.")
        case let .queued(revision):
            if let pending = currentDisplay.pendingRender, pending.revision == revision {
                if let date = pending.renderedAt {
                    Text(String(localized: "Rendered · \(projectionDateText(date, timezone: displayTimezone.identifier))"))
                }
                Text("Waiting for device collection; timing is unknown.")
                Text("Screen appearance is not confirmed.")
            } else {
                Text("This queued frame is no longer available.")
            }
        case let .planned(event):
            Text(event.event.dashboardName ?? String(localized: "Planned dashboard preview"))
            Text(projectionDateText(event.event.scheduledAt, timezone: effectiveServerTimezone(model.activeInstance?.timezone, fallbackID: event.timezone).identifier))
            Text([plannedCertaintyTitle(event.event.certainty), event.event.effect == .changeScreen ? String(localized: "Changes the screen") : String(localized: "Refreshes the current screen")].joined(separator: " · "))
            Text("A preview of planned content. It may change before the update runs and does not indicate a rendered or queued frame.")
        }
    }

    private var screenPages: [ScreenPage] {
        currentDisplay.pendingRender != nil && !local.isBluetooth && !local.usesLocalPreview
            ? [.recent, .queued] : [.recent]
    }

    private var visibleScreenPage: ScreenPage {
        screenPages.contains(selectedScreenPage) ? selectedScreenPage : .recent
    }

    private var screenPageSelection: Binding<ScreenPage> {
        Binding(get: { visibleScreenPage }, set: { selectedScreenPage = $0 })
    }

    private func screenPageTitle(_ page: ScreenPage) -> String {
        switch page {
        case .recent: local.isBluetooth || local.usesLocalPreview ? previewTitle : String(localized: "Latest frame")
        case .queued: String(localized: "Queued frame")
        }
    }

    private var screenCarouselCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            if screenPages.count > 1 {
                let selectorLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                    : AnyLayout(HStackLayout(spacing: 12))
                selectorLayout {
                    ForEach(screenPages, id: \.self) { page in
                        Button { screenPageSelection.wrappedValue = page } label: {
                            HStack(spacing: 8) {
                                Text(screenPageTitle(page))
                                    .fixedSize(horizontal: false, vertical: true)
                                Image(systemName: "checkmark")
                                    .opacity(visibleScreenPage == page ? 1 : 0)
                                    .accessibilityHidden(true)
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(visibleScreenPage == page ? TesseraeTheme.accent : Color.secondary)
                        .accessibilityAddTraits(visibleScreenPage == page ? .isSelected : [])
                        .accessibilityIdentifier("display-select-\(page == .recent ? "recent" : "queued")-\(currentDisplay.id)")
                    }
                }
                TabView(selection: screenPageSelection) {
                    ForEach(screenPages, id: \.self) { page in
                        screenPageArtwork(page)
                            .tag(page)
                            .accessibilityHidden(visibleScreenPage != page)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 240)
            } else {
                Text(screenPageTitle(.recent)).font(.headline)
                screenPageArtwork(.recent).frame(height: 240)
            }
            screenPageTimestamp
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            if currentDisplay.hasPendingRender == true && screenPages.count == 1
                && !local.isBluetooth && !local.usesLocalPreview {
                pendingRefreshExplanation
            }
        }
        .tesseraeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("display-latest-frame-\(currentDisplay.id)")
    }

    private func screenPageArtwork(_ page: ScreenPage) -> some View {
        GeometryReader { geometry in
            let height = min(geometry.size.height, geometry.size.width / currentDisplay.panelAspectRatio)
            Button {
                switch page {
                case .recent: selectedPreview = .server
                case .queued:
                    if let pending = currentDisplay.pendingRender { selectedPreview = .queued(pending.revision) }
                }
            } label: {
                switch page {
                case .recent: currentScreenPreview
                case .queued: nextScreenPreview
                }
            }
            .buttonStyle(.plain)
            .frame(width: height * currentDisplay.panelAspectRatio, height: height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(screenPageTitle(page))
            .accessibilityIdentifier("display-open-\(page == .recent ? "preview" : "queued-preview")-\(currentDisplay.id)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var screenPageTimestamp: some View {
        switch visibleScreenPage {
        case .recent:
            if local.usesLocalPreview, let date = local.record?.photoReceivedAt {
                Text(compactProjectionDateText(date, timezone: displayTimezone.identifier))
            } else if let date = plan.response?.currentFrameAt {
                Text(compactProjectionDateText(date, timezone: displayTimezone.identifier))
            }
        case .queued:
            if let date = currentDisplay.pendingRender?.renderedAt {
                Text(String(localized: "Rendered · \(compactProjectionDateText(date, timezone: displayTimezone.identifier))"))
            }
        }
    }

    @ViewBuilder
    private var planCard: some View {
        if !local.isBluetooth {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next planned").font(.subheadline.weight(.semibold))
                    if let next = plan.next {
                        plannedEventRow(next)
                    } else {
                        DisplayPlanSummary(plan: plan, showsNextHeading: false)
                    }
                    if plan.next != nil {
                        if plan.error != nil {
                            Text("Previous projection · Refresh failed").font(.caption).foregroundStyle(.secondary)
                            if let response = plan.response {
                                Text(String(localized: "Projection generated \(projectionDateText(response.generatedAt, timezone: response.timezone)) · Through \(projectionDateText(response.throughAt, timezone: response.timezone))"))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let error = plan.error { Text(error).font(.caption).foregroundStyle(.secondary) }
                        }
                        if plan.isRefreshing { Text("Refreshing…").font(.caption).foregroundStyle(.secondary) }
                    }
                    if !plan.subsequentEvents.isEmpty {
                        Button { laterExpanded.toggle() } label: {
                            HStack {
                                Text("\(plan.subsequentEvents.count) more updates")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(laterExpanded ? 90 : 0))
                                    .accessibilityHidden(true)
                            }
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(laterExpanded ? Text("Expanded") : Text("Collapsed"))
                        .accessibilityIdentifier("display-later-updates")
                        if laterExpanded {
                            ForEach(plan.subsequentEvents) { event in
                                Divider()
                                plannedEventRow(event)
                            }
                        }
                    }
                    if plan.error != nil {
                        Button("Retry") {
                            Task { await model.refreshDeviceUpcoming(displayID: currentDisplay.id, showErrors: true) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("display-next-update-\(currentDisplay.id)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tesseraeCard()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("display-evidence-\(currentDisplay.id)")
        }
    }


    private func plannedEventRow(_ event: PlannedDisplayEvent) -> some View {
        evidenceLayout {
            if let dashboardID = event.event.dashboardID {
                Button { selectedPreview = .planned(event) } label: {
                    PlannedDashboardThumbnail(dashboardID: dashboardID, display: currentDisplay)
                }
                .buttonStyle(.plain)
                .frame(minHeight: 44)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Planned dashboard preview")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text([compactProjectionDateText(event.event.scheduledAt, timezone: displayTimezone.identifier), event.event.dashboardName].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline.weight(.semibold))
                if event.event.certainty != .scheduled || event.event.effect == .refreshScreen {
                    Text([event.event.certainty != .scheduled ? plannedCertaintyTitle(event.event.certainty) : nil,
                          event.event.effect == .refreshScreen ? String(localized: "Refreshes the current screen") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let lineupID = event.event.lineupID {
                    NavigationLink(value: LineupRoute.lineup(id: lineupID, displayID: currentDisplay.id)) {
                        Label(event.event.lineupName ?? lineupID, systemImage: "rectangle.stack")
                            .font(.caption)
                            .frame(minHeight: 44, alignment: .leading)
                    }
                    .accessibilityIdentifier("display-planned-lineup-\(event.event.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var displayLineupsCard: some View {
        let lineups = model.lineups.filter {
            model.supportsLineups &&
            resolvedLineupDeviceIDs(explicitDeviceIDs: $0.deviceIDs, serverResolvedDeviceIDs: $0.resolvedDeviceIDs).contains(currentDisplay.id)
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Lineups for this display").font(.headline)
            ForEach(lineups) { lineup in
                NavigationLink(value: LineupRoute.lineup(id: lineup.id, displayID: currentDisplay.id)) {
                    LineupListRow(
                        lineup: lineup,
                        plans: displayPlanProjections(
                            deviceIDs: [currentDisplay.id], displays: model.displays,
                            supported: model.supportsDeviceTimeline, responses: model.deviceUpcomingResponses,
                            refreshing: model.loadingDeviceTimelineIDs, errors: model.deviceTimelineErrors,
                            lineupID: lineup.id
                        ),
                        showsPlan: false
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("display-lineup-\(lineup.id)")
            }
            if !model.supportsLineups {
                Text("Lineups are not supported by this server.").font(.caption).foregroundStyle(.secondary)
            } else if let error = model.lineupsReadError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            } else if lineups.isEmpty {
                if model.isRefreshingLineups {
                    ProgressView("Loading Lineups…")
                } else if model.hasReadCurrentLineups {
                    Text("No Lineups assigned").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Lineups not loaded").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }

    private var currentScreenPreview: some View {
        PreviewArtwork(
            state: local.preview ?? model.displayPreviews[currentDisplay.id],
            placeholderSystemName: currentDisplay.previewSymbol,
            placeholderLabel: "Display preview placeholder, \(currentDisplay.panel.width) by \(currentDisplay.panel.height), \(currentDisplay.panel.orientation)",
            imageLabel: previewTitle,
            accessibilityIdentifier: "display-detail-preview-\(currentDisplay.id)",
            placeholderDetail: "\(currentDisplay.panel.width) × \(currentDisplay.panel.height)"
        )
    }

    private var nextScreenPreview: some View {
        PreviewArtwork(
            state: model.pendingDisplayPreview(for: currentDisplay),
            placeholderSystemName: currentDisplay.previewSymbol,
            placeholderLabel: "Queued frame",
            imageLabel: String(localized: "Queued frame"),
            accessibilityIdentifier: "display-detail-pending-preview-\(currentDisplay.id)"
        )
    }

    private var pendingRefreshExplanation: some View {
        HStack(alignment: .top, spacing: 10) {
            PendingRenderGlyph()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting for display refresh")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.warning)

                Text(
                    "A frame is queued. Device collection and screen appearance are not confirmed."
                )
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
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(
            "display-pending-status-\(currentDisplay.id)"
        )
    }


}

private struct DisplayDeviceDetails: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: DisplaySummary
    let local: DisplayBluetoothPresentation
    let timezoneID: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerButton

            if isExpanded {
                Divider()

                detailRow("Status") {
                    if local.isBluetooth {
                        BluetoothModeLabel()
                    } else {
                        Label(display.freshnessLabel, systemImage: display.freshnessSymbol)
                            .foregroundStyle(display.freshnessColor)
                    }
                }

                detailRow("Last Seen") {
                    if let lastSeenAt = local.lastSeenAt(fallback: display.lastSeenAt) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(lastSeenAt, style: .relative)
                            Text(lastSeenAt, format: absoluteDateFormat)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Not reported")
                    }
                }

                detailRow("Battery") {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(local.batteryText)
                        if let voltage = local.voltageText, voltage != local.batteryText {
                            Text(voltage).font(.caption).foregroundStyle(.secondary)
                        }
                        if let date = local.batteryDate {
                            Text(date, format: absoluteDateFormat)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

                if !local.isBluetooth {
                    detailRow("Signal") {
                        Text(display.rssiDBM.map { "\($0) dBm" } ?? String(localized: "Not reported"))
                            .accessibilityIdentifier("display-signal-\(display.id)")
                    }
                }
                Divider()

                if let timezoneID {
                    detailRow("Time Zone") { Text(timezoneID) }
                }

                detailRow("Manufacturer") {
                    Text(
                        display.hardwarePresentation.brand?.displayName
                            ?? String(localized: "Not reported")
                    )
                }

                detailRow("Model") {
                    Text(
                        display.hardwarePresentation.modelName
                            ?? String(localized: "Not reported")
                    )
                }

                detailRow("Firmware") {
                    Text(local.firmwareVersion ?? String(localized: "Not reported"))
                        .accessibilityIdentifier("display-firmware-\(display.id)")
                }

                detailRow("Device Type") {
                    Text(display.kind)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                detailRow("Device ID") {
                    Text(display.id)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Divider()

                detailRow("Resolution") {
                    Text("\(display.panel.width) × \(display.panel.height)")
                        .monospacedDigit()
                }

                detailRow("Orientation") {
                    Text(display.orientationLabel)
                }

                detailRow("Colour Gamut") {
                    Text(display.gamutLabel)
                }

            }
        }
        .tesseraeCard()
    }

    private var absoluteDateFormat: Date.FormatStyle {
        Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: effectiveServerTimezone(timezoneID))
            .timeZone(.specificName(.short))
    }

    private var headerButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Device information", systemImage: "cpu")
                        .font(.headline)
                        .foregroundStyle(Color.primary)

                    DisplayHardwareBadge(presentation: display.hardwarePresentation)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityIdentifier("display-device-details-\(display.id)")
    }

    private func detailRow<Value: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder value: () -> Value
    ) -> some View {
        LabeledContent {
            value()
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
                .foregroundStyle(.secondary)
        }
        .font(.subheadline)
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
        case .fresh: TesseraeTheme.success
        case .stale: TesseraeTheme.warning
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
