import SwiftUI
import TesseraeKit
import UIKit

struct DashboardsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var draggedDashboardID: String?
    @State private var dropTargetDashboardID: String?
    @State private var expandedDashboardID: String?
    @State private var dashboardToPush: DashboardSummary?
    private let previewCanvasSize = CGSize(width: 112, height: 118)

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 14) {
                ForEach(model.sortedDashboards) { dashboard in
                    dashboardCard(dashboard)
                        .onDrag {
                            draggedDashboardID = dashboard.id
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
                                dashboard.id,
                                targeted: targeted
                            )
                        }
                        .overlay {
                            if dropTargetDashboardID == dashboard.id {
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
                            value: model.sortedDashboards.map(\.id)
                        )
                        .accessibilityHint(
                            "Long press and drag to reorder."
                        )
                        .task(id: model.previewGeneration) {
                            await model.loadDashboardPreview(dashboard)
                        }
                }
            }
            .padding(16)
        }
        .refreshable {
            await model.refreshDashboards()
        }
        .sheet(item: $dashboardToPush) { dashboard in
            DashboardPushSheet(dashboard: dashboard)
                .environment(model)
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

    private func dashboardCard(_ dashboard: DashboardSummary) -> some View {
        let expandedImage = dashboardPreviewImage(for: dashboard)
        let isExpanded = expandedDashboardID == dashboard.id

        return VStack(
            alignment: .leading,
            spacing: isExpanded ? 14 : 0
        ) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        dashboardIcon(dashboard)

                        Text(dashboard.name)
                            .font(.headline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }

                    Text(dashboard.kind.rawValue.capitalized)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)

                    Label(
                        model.displayNames(for: dashboard.deviceIDs),
                        systemImage: "rectangle.connected.to.line.below"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                    Button {
                        dashboardToPush = dashboard
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
                    .accessibilityIdentifier("dashboard-push-\(dashboard.id)")
                    .disabled(
                        model.displays.isEmpty
                            || model.activeOperationIDs.contains(dashboard.id)
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                dashboardPreview(
                    dashboard,
                    canExpand: expandedImage != nil,
                    isExpanded: isExpanded
                )
            }

            if let expandedImage, isExpanded {
                expandedDashboardPreview(
                    expandedImage,
                    dashboard: dashboard
                )
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func dashboardIcon(_ dashboard: DashboardSummary) -> some View {
        PhosphorDashboardIcon(name: dashboard.canonicalIconName, size: 19)
    }

    private func dashboardPreview(
        _ dashboard: DashboardSummary,
        canExpand: Bool,
        isExpanded: Bool
    ) -> some View {
        let previewSize = dashboardPreviewSize(for: dashboard)
        let preview = ZStack {
            Color.clear

            PreviewArtwork(
                state: model.dashboardPreviews[dashboard.id],
                placeholderSystemName: dashboard.kind == .canvas
                    ? "scribble.variable"
                    : "square.grid.2x2",
                placeholderLabel: "Dashboard preview placeholder",
                imageLabel: "Cached visual preview for \(dashboard.name)",
                accessibilityIdentifier: "dashboard-preview-\(dashboard.id)"
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
                expandedDashboardID = isExpanded ? nil : dashboard.id
            }
        } label: {
            preview
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityIdentifier(
            "dashboard-preview-button-\(dashboard.id)"
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
        for dashboard: DashboardSummary
    ) -> UIImage? {
        model.dashboardPreviews[dashboard.id]?
            .data
            .flatMap(UIImage.init(data:))
    }

    private func expandedDashboardPreview(
        _ image: UIImage,
        dashboard: DashboardSummary
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
            "dashboard-preview-expanded-\(dashboard.id)"
        )
        .accessibilityLabel("Expanded preview for \(dashboard.name)")
    }

    private func dashboardPreviewSize(
        for dashboard: DashboardSummary
    ) -> CGSize {
        guard
            let targetID = dashboard.deviceIDs.first,
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
        Label(
            dashboard.name,
            systemImage: dashboard.kind == .canvas
                ? "scribble.variable"
                : "square.grid.2x2"
        )
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            TesseraeTheme.accent.opacity(0.9),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .onDisappear {
            endDashboardDrag()
        }
    }

    private func updateDropTarget(
        _ targetID: String,
        targeted: Bool
    ) {
        guard targeted else {
            if dropTargetDashboardID == targetID {
                withAnimation(.easeOut(duration: 0.12)) {
                    dropTargetDashboardID = nil
                }
            }
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            dropTargetDashboardID = targetID
        }

        guard
            let sourceID = draggedDashboardID,
            sourceID != targetID,
            let targetIndex = model.sortedDashboards.firstIndex(
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
            model.moveDashboard(
                sourceID,
                to: targetIndex
            )
        }
    }

    private func endDashboardDrag() {
        withAnimation(.easeOut(duration: 0.12)) {
            draggedDashboardID = nil
            dropTargetDashboardID = nil
        }
    }
}

private struct DashboardPushSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let dashboard: DashboardSummary

    @State private var selectedDeviceIDs: Set<String> = []
    @State private var didLoadInitialSelection = false
    @State private var contentHeight: CGFloat = 1
    @State private var sheetHeight: CGFloat = 400

    private let maximumContentHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Push Dashboard")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("dashboard-push-sheet-title")

                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 16)
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
                    let sent = await model.push(
                        dashboard,
                        deviceIDs: Array(selectedDeviceIDs).sorted()
                    )
                    if sent {
                        dismiss()
                    }
                }
            } label: {
                Label(
                    model.activeOperationIDs.contains(dashboard.id)
                        ? "Sending…"
                        : "Push to Selected Displays",
                    systemImage: "paperplane.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                selectedDeviceIDs.isEmpty
                    || model.activeOperationIDs.contains(dashboard.id)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .task {
            loadInitialSelection()
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
        .presentationDragIndicator(.visible)
    }

    private var dashboardPushContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text(dashboard.name)
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
                        "dashboard-push-preview-\(dashboard.id)"
                    )
                    .accessibilityLabel(
                        "Preview for \(dashboard.name)"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tesseraeCard()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Bound Displays")
                        .font(.headline)
                    Spacer()
                    if !boundDeviceIDs.isEmpty {
                        Button("Select All") {
                            selectedDeviceIDs = boundDeviceIDs
                        }
                        .font(.caption.weight(.semibold))
                    }
                }

                if boundDisplays.isEmpty {
                    ContentUnavailableView {
                        Label(
                            "No Bound Displays",
                            systemImage: "rectangle.badge.xmark"
                        )
                    } description: {
                        Text(
                            "Bind this dashboard to at least one display in Tesserae before pushing it from the app."
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(boundDisplays) { display in
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
                            "dashboard-push-device-\(display.id)"
                        )
                    }
                }
            }
            .tesseraeCard()
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var previewImage: UIImage? {
        model.dashboardPreviews[dashboard.id]?
            .data
            .flatMap(UIImage.init(data:))
    }

    private var boundDisplays: [DisplaySummary] {
        let boundIDs = Set(dashboard.deviceIDs)
        return model.displays.filter { boundIDs.contains($0.id) }
    }

    private var boundDeviceIDs: Set<String> {
        Set(boundDisplays.map(\.id))
    }

    private func loadInitialSelection() {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true

        selectedDeviceIDs = boundDeviceIDs
    }
}
