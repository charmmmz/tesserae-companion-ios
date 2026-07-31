import SwiftUI
import TesseraeKit
import UIKit

struct DashboardsView: View {
    @Environment(AppModel.self) private var model
    @State private var draggedDashboardID: String?
    @State private var dropTargetDashboardID: String?
    @State private var expandedPreview: DashboardPreviewSelection?
    @State private var dashboardToPush: DashboardSummary?
    private let previewCanvasSize = CGSize(width: 112, height: 118)

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
            await model.refresh()
        }
        .sheet(item: $expandedPreview) { preview in
            DashboardPreviewViewer(preview: preview)
        }
        .sheet(item: $dashboardToPush) { dashboard in
            DashboardPushSheet(dashboard: dashboard)
                .environment(model)
        }
        .overlay {
            if model.isRefreshing && model.dashboards.isEmpty {
                ProgressView("Loading dashboards…")
            } else if model.dashboards.isEmpty {
                ContentUnavailableView {
                    Label("No Dashboards", systemImage: "rectangle.grid.2x2")
                } description: {
                    Text("Create a Dashboard in Tesserae's web interface, then refresh.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .tesseraeScreenBackground()
    }

    private func dashboardCard(_ dashboard: DashboardSummary) -> some View {
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

            dashboardPreview(dashboard)
        }
        .tesseraeCard()
    }

    private func dashboardIcon(_ dashboard: DashboardSummary) -> some View {
        PhosphorDashboardIcon(name: dashboard.canonicalIconName, size: 19)
    }

    private func dashboardPreview(
        _ dashboard: DashboardSummary
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

        return ZStack {
            preview

            Button {
                openPreview(for: dashboard)
            } label: {
                Color.clear
                    .frame(
                        width: previewCanvasSize.width,
                        height: previewCanvasSize.height
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityIdentifier(
                "dashboard-preview-button-\(dashboard.id)"
            )
            .accessibilityLabel("Preview \(dashboard.name)")
            .accessibilityHint("Opens a full-size preview.")
        }
    }

    private func openPreview(for dashboard: DashboardSummary) {
        expandedPreview = DashboardPreviewSelection(
            id: dashboard.id,
            name: dashboard.name,
            image: model.dashboardPreviews[dashboard.id]?
                .data
                .flatMap(UIImage.init(data:))
        )
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(dashboard.name)
                            .font(.title3.weight(.semibold))
                        Text(
                            "Choose where to send this render. Dashboard bindings are not changed."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tesseraeCard()

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Displays")
                                .font(.headline)
                            Spacer()
                            if !boundDeviceIDs.isEmpty {
                                Button("Use Bindings") {
                                    selectedDeviceIDs = boundDeviceIDs
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }

                        ForEach(model.displays) { display in
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

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(display.name)
                                            .foregroundStyle(.primary)
                                        if dashboard.deviceIDs.contains(
                                            display.id
                                        ) {
                                            Text("Dashboard binding")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }

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
                        }
                    }
                    .tesseraeCard()

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
                }
                .padding(16)
            }
            .navigationTitle("Push Dashboard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadInitialSelection()
            }
            .tesseraeScreenBackground()
        }
        .presentationDetents([.medium, .large])
    }

    private var boundDeviceIDs: Set<String> {
        let availableIDs = Set(model.displays.map(\.id))
        return Set(dashboard.deviceIDs).intersection(availableIDs)
    }

    private func loadInitialSelection() async {
        guard !didLoadInitialSelection else { return }
        didLoadInitialSelection = true

        if !boundDeviceIDs.isEmpty {
            selectedDeviceIDs = boundDeviceIDs
            return
        }

        let availableIDs = Set(model.displays.map(\.id))
        if let preferences = await model.savedSendPreferences() {
            let preferred = Set(preferences.deviceIDs)
                .intersection(availableIDs)
            if !preferred.isEmpty {
                selectedDeviceIDs = preferred
                return
            }
        }
        selectedDeviceIDs = Set(model.displays.prefix(1).map(\.id))
    }
}

private struct DashboardPreviewSelection: Identifiable {
    let id: String
    let name: String
    let image: UIImage?
}

private struct DashboardPreviewViewer: View {
    @Environment(\.dismiss) private var dismiss
    let preview: DashboardPreviewSelection

    var body: some View {
        NavigationStack {
            Group {
                if let image = preview.image {
                    ZoomableDashboardImage(image: image)
                        .background(Color.black)
                } else {
                    ContentUnavailableView {
                        Label(
                            "Preview Unavailable",
                            systemImage: "photo.badge.exclamationmark"
                        )
                    } description: {
                        Text(
                            "Tesserae has not provided an image for this Dashboard."
                        )
                    }
                    .tesseraeScreenBackground()
                }
            }
            .accessibilityIdentifier(
                "dashboard-preview-viewer-\(preview.id)"
            )
            .accessibilityLabel(
                "Full-size preview for \(preview.name)"
            )
            .accessibilityHint(
                "Pinch to zoom, or double-tap to zoom in and out."
            )
            .navigationTitle(preview.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct ZoomableDashboardImage: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> DashboardImageScrollView {
        DashboardImageScrollView(image: image)
    }

    func updateUIView(
        _ scrollView: DashboardImageScrollView,
        context: Context
    ) {
        scrollView.setImage(image)
    }
}

private final class DashboardImageScrollView:
    UIScrollView,
    UIScrollViewDelegate
{
    private let imageView = UIImageView()
    private var lastLayoutSize: CGSize = .zero

    init(image: UIImage) {
        super.init(frame: .zero)

        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 5
        bouncesZoom = true
        decelerationRate = .fast
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        backgroundColor = .black

        imageView.contentMode = .scaleAspectFit
        imageView.layer.magnificationFilter = .nearest
        imageView.layer.minificationFilter = .trilinear
        addSubview(imageView)
        setImage(image)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: UIImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        lastLayoutSize = .zero
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0 else { return }
        if bounds.size != lastLayoutSize {
            lastLayoutSize = bounds.size
            setZoomScale(minimumZoomScale, animated: false)
            imageView.frame = CGRect(
                origin: .zero,
                size: fittedImageSize()
            )
            contentSize = imageView.bounds.size
        }
        centerImage()
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    private func fittedImageSize() -> CGSize {
        guard
            let image = imageView.image,
            image.size.width > 0,
            image.size.height > 0
        else {
            return bounds.size
        }

        let scale = min(
            bounds.width / image.size.width,
            bounds.height / image.size.height
        )
        return CGSize(
            width: image.size.width * scale,
            height: image.size.height * scale
        )
    }

    private func centerImage() {
        let horizontalInset = max(
            0,
            (bounds.width - contentSize.width) / 2
        )
        let verticalInset = max(
            0,
            (bounds.height - contentSize.height) / 2
        )
        contentInset = UIEdgeInsets(
            top: verticalInset,
            left: horizontalInset,
            bottom: verticalInset,
            right: horizontalInset
        )
    }

    @objc private func handleDoubleTap(
        _ recognizer: UITapGestureRecognizer
    ) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        let targetScale = min(2.5, maximumZoomScale)
        let point = recognizer.location(in: imageView)
        let zoomSize = CGSize(
            width: bounds.width / targetScale,
            height: bounds.height / targetScale
        )
        zoom(
            to: CGRect(
                x: point.x - zoomSize.width / 2,
                y: point.y - zoomSize.height / 2,
                width: zoomSize.width,
                height: zoomSize.height
            ),
            animated: true
        )
    }
}
