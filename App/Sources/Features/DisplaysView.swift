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
    @State private var displayFrames: [String: CGRect] = [:]
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
        }
        .navigationSplitViewStyle(.balanced)
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
            .onPreferenceChange(DisplayCardFrameKey.self) { frames in
                displayFrames = frames
            }
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
        Button("Manage Lineups", systemImage: "rectangle.3.group") {
            lineupsPresented = true
        }
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
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: DisplayCardFrameKey.self,
                    value: [
                        display.id: proxy.frame(
                            in: .named("displays-scroll")
                        )
                    ]
                )
            }
        )
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
                ? String(localized: "Bluetooth Mode") : (display.rssiDBM.map { "\($0) dBm" } ?? "—")))
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
            let cachedSourceFrame = displayFrames[displayID]
                ?? displayFrames.values.first
        else { return }

        // Preference values can briefly retain the right slot positions under
        // the wrong IDs while LazyVStack is animating a previous reorder. Use
        // them only for card size, then rebuild ordered slots around the exact
        // frame origin reported by the recognizer for the card being lifted.
        let slotStride = cachedSourceFrame.height + displayCardSpacing
        let correctedFrames = Dictionary(
            uniqueKeysWithValues: displayOrder.enumerated().map { index, id in
                let offset = CGFloat(index - sourceIndex) * slotStride
                return (
                    id,
                    CGRect(
                        x: currentOrigin.x,
                        y: currentOrigin.y + offset,
                        width: cachedSourceFrame.width,
                        height: cachedSourceFrame.height
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

private struct DisplayCardFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue()) { _, new in new }
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
                        metric("wifi", display.rssiDBM.map { "\($0) dBm" } ?? "—")
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
                    imageLabel: local.usesLocalPreview ? String(localized: "Last Bluetooth Send") : String(localized: "Last-served device preview for \(display.name)"),
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

private struct DisplayDetailView: View {
    @Environment(NearbyDeviceManager.self) private var nearby
    private var local: DisplayBluetoothPresentation {
        nearby.displayRecords.presentation(for: currentDisplay, serverID: model.activeInstance?.id)
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private enum ScreenPage: Hashable {
        case current
        case next
    }

    private struct UpdateAnchor: Equatable {
        let eventID: String
        let start: Date
        let end: Date
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedScreenPage: ScreenPage = .current
    @State private var updateAnchor: UpdateAnchor?
    @State private var hapticEvent = TesseraeHapticEvent()
    let display: DisplaySummary

    private var currentDisplay: DisplaySummary {
        model.displays.first(where: { $0.id == display.id }) ?? display
    }

    private var visibleScreenPage: ScreenPage {
        currentDisplay.pendingRender == nil || local.isBluetooth || local.usesLocalPreview ? .current : selectedScreenPage
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                screenCarouselCard

                if shouldShowNextUpdateCard {
                    nextUpdateCard
                }

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
                        }
                    }
                }

                DisplayDeviceDetails(display: currentDisplay)
            }
            .padding(16)
        }
        .navigationTitle(currentDisplay.name)
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
        .task(id: currentDisplay.pendingRender?.revision) {
            await model.loadPendingDisplayPreview(currentDisplay)
        }
        .task(id: "\(currentDisplay.id)-\(model.supportsDeviceTimeline)") {
            await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
        }
        .task(id: nextUpcomingEvent?.id) {
            if let event = nextUpcomingEvent {
                let needsReanchor: Bool
                if let anchor = updateAnchor {
                    needsReanchor = abs(
                        anchor.end.timeIntervalSince(event.scheduledAt)
                    ) > 30
                } else {
                    needsReanchor = true
                }
                if needsReanchor {
                    updateAnchor = UpdateAnchor(
                        eventID: event.id,
                        start: Date(),
                        end: event.scheduledAt
                    )
                } else if let anchor = updateAnchor,
                          anchor.eventID != event.id
                {
                    updateAnchor = UpdateAnchor(
                        eventID: event.id,
                        start: anchor.start,
                        end: anchor.end
                    )
                }
            }
            guard let scheduledAt = nextUpcomingEvent?.scheduledAt else { return }
            let delay = scheduledAt.timeIntervalSinceNow
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay + 1))
            }
            while !Task.isCancelled {
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
                guard
                    let event = model.deviceUpcomingResponses[currentDisplay.id]?
                        .events.first,
                    event.scheduledAt.timeIntervalSinceNow <= 10
                else {
                    break
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
        .onChange(of: currentDisplay.lastSeenAt) { _, _ in
            Task {
                await model.refreshDeviceUpcoming(displayID: currentDisplay.id)
            }
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

    private var shouldShowNextUpdateCard: Bool {
        guard model.supportsDeviceTimeline, !local.isBluetooth else { return false }
        if model.loadingDeviceTimelineIDs.contains(currentDisplay.id) {
            return true
        }
        if model.deviceTimelineErrors[currentDisplay.id] != nil {
            return true
        }
        return model.deviceUpcomingResponses[currentDisplay.id]?.events.isEmpty == false
    }

    @ViewBuilder
    private var nextUpdateCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Next in Line", systemImage: "clock.arrow.circlepath")
                .font(.headline)

            if let event = nextUpcomingEvent {
                TimelineView(.animation) { context in
                    nextUpdateContent(
                        event: event,
                        now: context.date
                    )
                }

                if !upcomingQueue.isEmpty {
                    Divider()
                    upcomingQueueList
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
            }
        }
        .tesseraeCard()
        .accessibilityIdentifier("display-next-update-\(currentDisplay.id)")
    }

    private var upcomingQueue: [DeviceUpcomingEvent] {
        guard let response = upcomingResponse else { return [] }
        return Array(response.events.dropFirst().prefix(4))
    }

    private var upcomingQueueList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(upcomingQueue.enumerated()), id: \.element.id) {
                index,
                event in
                HStack(spacing: 10) {
                    upcomingQueueIcon(for: event)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(upcomingTarget(event))
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(upcomingReason(event))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Text(
                        event.scheduledAt,
                        format: .dateTime.weekday(.abbreviated).hour().minute()
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                }

                if index < upcomingQueue.count - 1 {
                    Divider()
                }
            }
        }
        .accessibilityIdentifier("display-next-in-line-queue-\(currentDisplay.id)")
    }

    @ViewBuilder
    private func upcomingQueueIcon(for event: DeviceUpcomingEvent) -> some View {
        if let dashboardID = event.dashboardID,
           let dashboard = model.dashboards.first(where: { $0.id == dashboardID })
        {
            PhosphorIcon(
                name: dashboard.iconName,
                size: 15,
                color: TesseraeTheme.accent,
                fallbackSystemName: "rectangle.grid.2x2"
            )
        } else {
            Image(systemName: upcomingSymbol(event))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func nextUpdateContent(
        event: DeviceUpcomingEvent,
        now: Date
    ) -> some View {
        let isDue = event.scheduledAt <= now.addingTimeInterval(10)
        return VStack(alignment: .leading, spacing: 12) {
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
                    if isDue {
                        Text("Waiting for display…")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(upcomingAccent(event.certainty))
                    } else {
                        Text(event.scheduledAt, style: .relative)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(upcomingAccent(event.certainty))
                    }
                    Text(
                        event.scheduledAt,
                        format: .dateTime.weekday(.abbreviated).hour().minute()
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if let anchor = updateAnchor {
                let total = max(anchor.end.timeIntervalSince(anchor.start), 1)
                ProgressView(
                    value: min(
                        max(now.timeIntervalSince(anchor.start), 0),
                        total
                    ),
                    total: total
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

    private func upcomingTarget(_ event: DeviceUpcomingEvent) -> String {
        event.dashboardName
            ?? event.lineupName
            ?? String(localized: "Lineup update")
    }

    private func upcomingReason(_ event: DeviceUpcomingEvent) -> String {
        switch event.cause {
        case .interval:
            String(localized: "Keep Fresh")
        case .cycle:
            String(localized: "Cycle")
        case .daily:
            String(localized: "Daily")
        case .homeReturn:
            String(localized: "Home Return")
        case .dashboardRefresh:
            String(localized: "Dashboard refresh")
        case .widgetRefresh:
            String(localized: "Widget refresh")
        }
    }

    private func upcomingAccent(_ certainty: DeviceUpcomingCertainty) -> Color {
        certainty == .scheduled ? TesseraeTheme.info : TesseraeTheme.warning
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

            TabView(selection: Binding(get: { visibleScreenPage }, set: { selectedScreenPage = $0 })) {
                currentScreenPreview
                    .tag(ScreenPage.current)

                if currentDisplay.pendingRender != nil && !local.isBluetooth && !local.usesLocalPreview {
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

            if currentDisplay.pendingRender != nil && !local.isBluetooth && !local.usesLocalPreview {
                screenPageIndicator
            }

            if currentDisplay.hasPendingRender == true, !local.isBluetooth, !local.usesLocalPreview,
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
            reduceMotion ? nil : .easeInOut(duration: 0.22),
            value: visibleScreenPage
        )
    }

    private var screenPageHeader: some View {
        ZStack(alignment: .leading) {
            Label(local.isBluetooth && !local.usesLocalPreview ? String(localized: "Last Server Preview") : String(localized: "Current Screen"), systemImage: "display")
                .font(.headline)
                .opacity(visibleScreenPage == .current ? 1 : 0)
                .accessibilityHidden(visibleScreenPage != .current)

            HStack(spacing: 10) {
                Label("Next Screen", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(TesseraeTheme.warning)
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
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: visibleScreenPage)
    }

    private var currentScreenPreview: some View {
        PreviewArtwork(
            state: local.preview ?? model.displayPreviews[currentDisplay.id],
            placeholderSystemName: currentDisplay.previewSymbol,
            placeholderLabel: "Display preview placeholder, \(currentDisplay.panel.width) by \(currentDisplay.panel.height), \(currentDisplay.panel.orientation)",
            imageLabel: local.usesLocalPreview ? String(localized: "Last Bluetooth Send") : String(localized: "Last-served device preview for \(currentDisplay.name)"),
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
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
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
                        reduceMotion ? nil : .easeInOut(duration: 0.2),
                        value: visibleScreenPage
                    )
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
        .accessibilityAddTraits(visibleScreenPage == page ? .isSelected : [])
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
                    "The new frame will appear the next time this display wakes."
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
                    Text(display.firmwareVersion ?? String(localized: "Not reported"))
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
