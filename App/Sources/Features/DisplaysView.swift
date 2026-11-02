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
    case planned(String)

    var id: String {
        switch self {
        case .server: "server"
        case let .queued(revision): "queued|\(revision)"
        case let .planned(id): "planned|\(id)"
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
    @State private var selectedPreview: DisplayEvidencePreview?
    let display: DisplaySummary

    private var currentDisplay: DisplaySummary {
        model.displays.first(where: { $0.id == display.id }) ?? display
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                screenEvidenceCard

                detailCard(
                    "Connection & Power",
                    systemImage: "antenna.radiowaves.left.and.right"
                ) {
                    detailRow("Status") {
                        if local.isBluetooth {
                            BluetoothModeLabel()
                        } else {
                            Label(currentDisplay.freshnessLabel, systemImage: currentDisplay.freshnessSymbol)
                                .foregroundStyle(currentDisplay.freshnessColor)
                        }
                    }

                    detailRow("Last Seen") {
                        if let lastSeenAt = local.lastSeenAt(fallback: currentDisplay.lastSeenAt) {
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
                        VStack(alignment: .trailing, spacing: 3) {
                            Text(local.batteryText)
                            if let voltage = local.voltageText, voltage != local.batteryText {
                                Text(voltage).font(.caption).foregroundStyle(.secondary)
                            }
                            if let date = local.batteryDate {
                                Text(date, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    if !local.isBluetooth {
                        detailRow("Signal") {
                            Text(currentDisplay.rssiDBM.map { "\($0) dBm" } ?? String(localized: "Not reported"))
                                .accessibilityIdentifier("display-signal-\(currentDisplay.id)")
                        }
                    }
                }

                DisplayDeviceDetails(display: currentDisplay, firmwareVersion: local.firmwareVersion)
                displayLineupsCard
            }
            .padding(16)
        }
        .navigationTitle(currentDisplay.name)
        .tesseraeRootPageChrome()
        .navigationBarTitleDisplayMode(.inline)
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
                    PreviewArtwork(
                        state: evidencePreviewState(preview),
                        placeholderSystemName: currentDisplay.previewSymbol,
                        placeholderLabel: evidencePreviewTitle(preview),
                        imageLabel: evidencePreviewTitle(preview),
                        accessibilityIdentifier: "display-evidence-preview-sheet"
                    )
                    .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
                    .padding(20)
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
        case let .planned(id): model.dashboardPreview(id: id, deviceID: currentDisplay.id)
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

    private var previewTitle: String {
        local.usesLocalPreview ? String(localized: "Last Bluetooth Send") : String(localized: "Server preview")
    }

    private var screenEvidenceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Button { selectedPreview = .server } label: {
                    currentScreenPreview
                        .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
                        .frame(width: 112).frame(maxHeight: 160)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(previewTitle)
                .accessibilityIdentifier("display-open-preview-\(currentDisplay.id)")
                VStack(alignment: .leading, spacing: 7) {
                    Label(previewTitle, systemImage: local.usesLocalPreview ? "paperplane" : "display")
                        .font(.headline)
                    Text(local.usesLocalPreview ? "Saved from a local Bluetooth Send." : "The latest preview available from the server.")
                        .font(.caption).foregroundStyle(.secondary)
                    if local.usesLocalPreview, let date = local.record?.photoReceivedAt {
                        Text(String(localized: "Local Send record · \(projectionDateText(date, timezone: model.activeInstance?.timezone ?? "UTC"))"))
                            .font(.caption2).foregroundStyle(.secondary)
                    } else if let frameAt = plan.response?.currentFrameAt {
                        Text(String(localized: "Last served or published · \(projectionDateText(frameAt, timezone: plan.response?.timezone ?? model.activeInstance?.timezone ?? "UTC"))"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("Screen appearance is not confirmed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let pending = currentDisplay.pendingRender, !local.isBluetooth, !local.usesLocalPreview {
                HStack(spacing: 12) {
                    Image(systemName: "hourglass").foregroundStyle(TesseraeTheme.warning)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Queued frame").font(.subheadline.weight(.semibold))
                        Text("Waiting for device collection; timing is unknown.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let renderedAt = pending.renderedAt {
                            Text(String(localized: "Rendered · \(projectionDateText(renderedAt, timezone: plan.response?.timezone ?? model.activeInstance?.timezone ?? "UTC"))"))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button { selectedPreview = .queued(pending.revision) } label: {
                        nextScreenPreview
                            .aspectRatio(currentDisplay.panelAspectRatio, contentMode: .fit)
                            .frame(width: 60).frame(maxHeight: 90)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Queued frame")
                }
                .padding(10)
                .background(TesseraeTheme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("display-queued-frame-\(currentDisplay.id)")
            } else if currentDisplay.hasPendingRender == true, !local.isBluetooth, !local.usesLocalPreview {
                pendingRefreshExplanation
            }

            if !local.isBluetooth {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Next planned update", systemImage: "clock")
                        .font(.subheadline.weight(.semibold))
                    HStack(alignment: .top, spacing: 12) {
                        DisplayPlanSummary(plan: plan, showsNextHeading: false)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let next = plan.next, let dashboardID = next.event.dashboardID {
                            Button { selectedPreview = .planned(dashboardID) } label: {
                                PlannedDashboardThumbnail(dashboardID: dashboardID, display: currentDisplay)
                            }
                            .buttonStyle(.plain)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel("Planned dashboard preview")
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
        }
        .tesseraeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("display-evidence-\(currentDisplay.id)")
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
                        )
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

private struct DisplayDeviceDetails: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let display: DisplaySummary
    let firmwareVersion: String?
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerButton

            if isExpanded {
                Divider()

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
                    Text(firmwareVersion ?? String(localized: "Not reported"))
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

    private var headerButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Device Details", systemImage: "cpu")
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
