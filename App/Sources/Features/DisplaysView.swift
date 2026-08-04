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
    @State private var draggedDisplayID: String?
    @State private var dropTargetDisplayID: String?
    @State private var selectedDisplay: DisplaySummary?

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.sortedDisplays) { display in
                    Button {
                        selectedDisplay = display
                    } label: {
                        DisplayCard(
                            display: display,
                            preview: model.displayPreviews[display.id]
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("display-card-\(display.id)")
                    .onDrag {
                        draggedDisplayID = display.id
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
                            .transition(.opacity)
                        }
                    }
                    .animation(
                        .spring(
                            response: 0.28,
                            dampingFraction: 0.82
                        ),
                        value: model.sortedDisplays.map(\.id)
                    )
                    .accessibilityHint(
                        "Long press and drag to reorder."
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
                await model.refreshDisplays(
                    showErrors: false,
                    saveSnapshot: false
                )
            }
        }
        .tesseraeScreenBackground()
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
                withAnimation(.easeOut(duration: 0.12)) {
                    dropTargetDisplayID = nil
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetDisplayID = targetID
        }

        guard
            let sourceID = draggedDisplayID,
            sourceID != targetID,
            let targetIndex = model.sortedDisplays.firstIndex(
                where: { $0.id == targetID }
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
            model.moveDisplay(sourceID, to: targetIndex)
        }
    }

    private func endDisplayDrag() {
        withAnimation(.easeOut(duration: 0.12)) {
            draggedDisplayID = nil
            dropTargetDisplayID = nil
        }
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
    @State private var selectedScreenPage: ScreenPage = .current
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
        .onChange(of: currentDisplay.pendingRender?.revision) { _, revision in
            if revision == nil {
                selectedScreenPage = .current
            }
        }
        .tesseraeScreenBackground()
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
