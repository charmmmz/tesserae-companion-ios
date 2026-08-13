import SwiftUI
import TesseraeKit
import ImageIO
import UIKit

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.presentTesseraeSettings) private var presentSettings
    @State private var expandedQueuedImageID: String?
    @State private var expandedJobID: String?
    @State private var expandedHistoryID: String?
    private let previewCanvasSize = CGSize(width: 112, height: 118)

    let isActive: Bool

    private var shouldAutoRefresh: Bool {
        isActive && scenePhase == .active
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.queuedImageRequests) { request in
                    queuedImageCard(request)
                }
                ForEach(model.queuedLinkRequests) { request in
                    queuedLinkCard(request)
                }
                ForEach(visibleJobs) { job in
                    activityCard(job)
                }
                ForEach(visibleHistoryItems) { item in
                    historyCard(item)
                }
                if model.historyNextBeforeID != nil {
                    Button {
                        Task { await model.loadMoreHistory() }
                    } label: {
                        if model.isLoadingMoreHistory {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label(
                                "Load Older Activity",
                                systemImage: "clock.badge.plus"
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isLoadingMoreHistory)
                }
            }
            .padding(16)
        }
        .overlay {
            if model.queuedImageRequests.isEmpty
                && model.queuedLinkRequests.isEmpty
                && visibleJobs.isEmpty
                && visibleHistoryItems.isEmpty
            {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text(
                        "Dashboard, photo, and link sends will appear here."
                    )
                )
            }
        }
        .refreshable {
            model.startActivityRefresh()
        }
        .task(id: shouldAutoRefresh) {
            guard shouldAutoRefresh else { return }

            await model.refreshActivity(
                showErrors: false,
                saveSnapshot: false
            )
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                await model.refreshActivity(
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
    }

    private func queuedLinkCard(
        _ request: SharedLinkRequest
    ) -> some View {
        let isActive = model.activeQueuedLinkRequestIDs.contains(request.id)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(request.url.host() ?? request.url.absoluteString)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(model.displayNames(for: request.deviceIDs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    HStack(spacing: 6) {
                        Text(fallbackTitle(request.jobKind))
                        Text("·")
                        Text(request.fit.displayName)
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                    Text(
                        request.createdAt,
                        format: .dateTime
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                queuedLinkArtwork(request)
            }

            if let lastError = request.lastError,
               request.status == .failed
            {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(TesseraeTheme.terracotta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task { await model.retryQueuedLink(request) }
                } label: {
                    Label(
                        isActive ? "Retrying…" : "Retry",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TesseraeTheme.accent)
                .disabled(isActive || model.connectionMode != .live)

                Button(role: .destructive) {
                    Task { await model.discardQueuedLink(request) }
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isActive)
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .accessibilityIdentifier("queued-link-card-\(request.id)")
    }

    private func queuedLinkArtwork(
        _ request: SharedLinkRequest
    ) -> some View {
        cardPreview(
            image: nil,
            panel: previewPanel(for: request.deviceIDs),
            fit: request.fit,
            placeholderSystemName: artworkSymbol(request.jobKind),
            tint: TesseraeTheme.ochre,
            accessibilityLabel: "Queued link preview placeholder",
            accessibilityIdentifier: "queued-link-preview-\(request.id)",
            statusLabel: queuedLinkStatusLabel(request),
            statusSymbol: queuedLinkStatusSymbol(request),
            statusColor: queuedLinkStatusColor(request),
            statusAccessibilityIdentifier:
                "queued-link-status-\(request.id)"
        )
    }

    private func queuedLinkStatusLabel(
        _ request: SharedLinkRequest
    ) -> String {
        switch request.status {
        case .queued:
            String(localized: "Waiting")
        case .submitting:
            String(localized: "Sending")
        case .failed:
            String(localized: "Failed")
        }
    }

    private func queuedLinkStatusSymbol(
        _ request: SharedLinkRequest
    ) -> String {
        switch request.status {
        case .queued:
            "clock"
        case .submitting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func queuedLinkStatusColor(
        _ request: SharedLinkRequest
    ) -> Color {
        switch request.status {
        case .queued, .submitting:
            TesseraeTheme.ochre
        case .failed:
            TesseraeTheme.terracotta
        }
    }

    private func queuedImageCard(
        _ request: SharedImageRequest
    ) -> some View {
        let thumbnail = model.queuedImagePreviewData[request.id]
            .flatMap {
                ActivityPhotoCache.shared.image(
                    for: "queued-\(request.id)",
                    data: $0
                )
            }
        let isExpanded = expandedQueuedImageID == request.id
        let isActive = model.activeQueuedImageRequestIDs.contains(request.id)

        return VStack(alignment: .leading, spacing: 12) {
            Button {
                guard thumbnail != nil else { return }
                withAnimation(.smooth(duration: 0.28)) {
                    expandedQueuedImageID = isExpanded ? nil : request.id
                }
            } label: {
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Queued photo")
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Text(model.displayNames(for: request.deviceIDs))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        HStack(spacing: 6) {
                            Text("File")
                            Text("·")
                            Text(request.fit.displayName)
                        }
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                        Text(
                            request.createdAt,
                            format: .dateTime
                                .month(.abbreviated)
                                .day()
                                .hour()
                                .minute()
                        )
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    queuedImageArtwork(request, thumbnail: thumbnail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let thumbnail, isExpanded {
                expandedPhoto(thumbnail)
                    .transition(.opacity)
            }

            if let lastError = request.lastError,
               request.status == .failed
            {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(TesseraeTheme.terracotta)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 12) {
                Button {
                    Task { await model.retryQueuedImage(request) }
                } label: {
                    Label(
                        isActive ? "Retrying…" : "Retry",
                        systemImage: "arrow.clockwise"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(TesseraeTheme.accent)
                .disabled(isActive || model.connectionMode != .live)

                Button(role: .destructive) {
                    Task { await model.discardQueuedImage(request) }
                } label: {
                    Label("Discard", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isActive)
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .task(id: request.id) {
            await model.loadQueuedImagePreview(request)
        }
        .accessibilityIdentifier("queued-image-card-\(request.id)")
    }

    private func queuedImageArtwork(
        _ request: SharedImageRequest,
        thumbnail: UIImage?
    ) -> some View {
        cardPreview(
            image: thumbnail,
            panel: previewPanel(for: request.deviceIDs),
            fit: request.fit,
            placeholderSystemName: "photo.badge.clock",
            tint: TesseraeTheme.ochre,
            accessibilityLabel: thumbnail == nil
                ? "Queued photo preview placeholder"
                : "Queued photo preview",
            accessibilityIdentifier: "queued-image-preview-\(request.id)",
            statusLabel: queuedImageStatusLabel(request),
            statusSymbol: queuedImageStatusSymbol(request),
            statusColor: queuedImageStatusColor(request),
            statusAccessibilityIdentifier:
                "queued-image-status-\(request.id)"
        )
    }

    private func queuedImageStatusLabel(
        _ request: SharedImageRequest
    ) -> String {
        switch request.status {
        case .queued:
            String(localized: "Waiting")
        case .submitting:
            String(localized: "Sending")
        case .failed:
            String(localized: "Failed")
        }
    }

    private func queuedImageStatusSymbol(
        _ request: SharedImageRequest
    ) -> String {
        switch request.status {
        case .queued:
            "clock"
        case .submitting:
            "arrow.triangle.2.circlepath"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private func queuedImageStatusColor(
        _ request: SharedImageRequest
    ) -> Color {
        switch request.status {
        case .queued, .submitting:
            TesseraeTheme.ochre
        case .failed:
            TesseraeTheme.terracotta
        }
    }

    private var visibleJobs: [PushJob] {
        guard model.supportsHistory else {
            return model.jobs
        }
        return ActivityReconciliation.visibleJobs(
            model.jobs,
            historyItems: model.historyItems
        )
    }

    private var visibleHistoryItems: [HistoryItem] {
        guard model.supportsHistory else {
            return model.historyItems
        }
        return ActivityReconciliation.visibleHistoryItems(
            model.historyItems,
            jobs: model.jobs
        )
    }

    @ViewBuilder
    private func activityCard(_ job: PushJob) -> some View {
        let thumbnail = model.activityThumbnailData[job.id]
            .flatMap {
                ActivityPhotoCache.shared.image(
                    for: "\(model.activeInstance?.id ?? "unknown")-\(job.id)",
                    data: $0
                )
            }

        if let thumbnail {
            Button {
                withAnimation(.smooth(duration: 0.28)) {
                    expandedJobID = expandedJobID == job.id
                        ? nil
                        : job.id
                }
            } label: {
                activityCardContent(
                    job,
                    thumbnail: thumbnail,
                    isExpanded: expandedJobID == job.id
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("activity-photo-card-\(job.id)")
            .accessibilityValue(
                expandedJobID == job.id
                    ? Text("Expanded")
                    : Text("Collapsed")
            )
            .accessibilityHint(
                expandedJobID == job.id
                    ? Text("Collapse photo preview")
                    : Text("Expand photo preview")
            )
        } else {
            activityCardContent(
                job,
                thumbnail: nil,
                isExpanded: false
            )
        }
    }

    private func activityCardContent(
        _ job: PushJob,
        thumbnail: UIImage?,
        isExpanded: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: isExpanded ? 14 : 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(job.label ?? fallbackTitle(job.kind))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(model.displayNames(for: job.targetDeviceIDs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

                    if let sourceLabel = linkSourceLabel(job.kind) {
                        Label(
                            sourceLabel,
                            systemImage: artworkSymbol(job.kind)
                        )
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    }

                    if let failure = job.error {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(TesseraeTheme.terracotta)
                            .lineLimit(isExpanded ? nil : 2)
                    }

                    Text(
                        job.createdAt,
                        format: .dateTime
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                jobArtwork(job, thumbnail: thumbnail)
            }

            if let thumbnail, isExpanded {
                expandedPhoto(thumbnail)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .shadow(
            color: .black.opacity(0.05),
            radius: 9,
            y: 4
        )
        .contentShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
    }

    private func historyCard(_ item: HistoryItem) -> some View {
        let preview = model.historyPreviews[item.id]?.data.flatMap {
            ActivityPhotoCache.shared.image(
                for: "\(model.activeInstance?.id ?? "unknown")-history-\(item.id)",
                data: $0
            )
        }
        let isExpanded = expandedHistoryID == item.id
        let isResending = model.activeOperationIDs.contains(
            "history-\(item.id)"
        )

        return VStack(alignment: .leading, spacing: isExpanded ? 14 : 0) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.label)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.displayNames(for: item))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let error = item.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(TesseraeTheme.terracotta)
                            .lineLimit(isExpanded ? nil : 2)
                    }
                    HStack(spacing: 6) {
                        Text(item.source.replacingOccurrences(
                            of: "_",
                            with: " "
                        ).capitalized)
                        if let fit = item.fit {
                            Text("·")
                            Text(fit.displayName)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    Text(
                        item.createdAt,
                        format: .dateTime
                            .month(.abbreviated)
                            .day()
                            .hour()
                            .minute()
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)

                    if item.resendable {
                        Button {
                            Task { await model.resend(item) }
                        } label: {
                            HStack(spacing: 5) {
                                if isResending {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Resend")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(isResending)
                        .accessibilityLabel(
                            isResending ? "Resending…" : "Resend"
                        )
                        .accessibilityIdentifier(
                            "history-resend-\(item.id)"
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    guard preview != nil else { return }
                    withAnimation(.smooth(duration: 0.28)) {
                        expandedHistoryID = isExpanded ? nil : item.id
                    }
                } label: {
                    historyArtwork(item, preview: preview)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-card-\(item.id)")
                .accessibilityValue(
                    isExpanded ? Text("Expanded") : Text("Collapsed")
                )
                .accessibilityHint(
                    isExpanded
                        ? Text("Collapse composition preview")
                        : Text("Expand composition preview")
                )
            }

            if let preview, isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    expandedPhoto(preview)
                    Text(historyPreviewCaption(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
        .clipShape(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .task(id: model.previewGeneration) {
            await model.loadHistoryPreview(item)
        }
    }

    @ViewBuilder
    private func historyArtwork(
        _ item: HistoryItem,
        preview: UIImage?
    ) -> some View {
        let status = historyStatusPresentation(item)

        cardPreview(
            image: preview,
            panel: previewPanel(for: item),
            fit: nil,
            placeholderSystemName: item.fit == nil
                ? "rectangle.grid.2x2"
                : "photo",
            tint: TesseraeTheme.accent,
            accessibilityLabel: preview == nil
                ? "Sent composition preview placeholder"
                : "Sent composition preview",
            accessibilityIdentifier: "history-preview-\(item.id)",
            statusLabel: status.label,
            statusSymbol: status.symbol,
            statusColor: status.color,
            statusAccessibilityIdentifier: "history-status-\(item.id)"
        )
    }

    private func jobArtwork(
        _ job: PushJob,
        thumbnail: UIImage?
    ) -> some View {
        cardPreview(
            image: thumbnail,
            panel: previewPanel(for: job.targetDeviceIDs),
            fit: nil,
            placeholderSystemName: artworkSymbol(job.kind),
            tint: TesseraeTheme.accent,
            accessibilityLabel: thumbnail == nil
                ? "Activity preview placeholder"
                : "Sent photo preview",
            accessibilityIdentifier: "activity-preview-\(job.id)",
            statusLabel: statusLabel(job),
            statusSymbol: statusSymbol(job),
            statusColor: statusColor(job),
            statusAccessibilityIdentifier: "activity-status-\(job.id)"
        )
    }

    private func cardPreview(
        image: UIImage?,
        panel: PanelProfile?,
        fit: ImageFitMode?,
        placeholderSystemName: String,
        tint: Color,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        statusLabel: String,
        statusSymbol: String,
        statusColor: Color,
        statusAccessibilityIdentifier: String
    ) -> some View {
        let fittedSize = previewSize(for: panel)

        return ZStack {
            Color.clear
                .accessibilityHidden(true)

            ZStack(alignment: .topTrailing) {
                ZStack {
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .fill(Color.primary.opacity(0.055))

                    if let image {
                        previewImage(
                            image,
                            panel: panel,
                            fit: fit,
                            size: fittedSize
                        )
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: placeholderSystemName)
                                .font(.title2)

                            if let panel {
                                Text(
                                    "\(panel.width) × \(panel.height)"
                                )
                                .font(.caption2.monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.68)
                            }
                        }
                        .padding(5)
                        .foregroundStyle(tint)
                    }
                }
                .frame(
                    width: fittedSize.width,
                    height: fittedSize.height
                )
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 12,
                        style: .continuous
                    )
                    .stroke(.white.opacity(0.16), lineWidth: 1)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilityLabel))
                .accessibilityValue(
                    panel.map {
                        Text("\($0.width) by \($0.height)")
                    } ?? Text("")
                )
                .accessibilityIdentifier(accessibilityIdentifier)

                compactStatus(
                    label: statusLabel,
                    symbol: statusSymbol,
                    color: statusColor
                )
                .padding(6)
                .accessibilityIdentifier(
                    statusAccessibilityIdentifier
                )
            }
            .frame(
                width: fittedSize.width,
                height: fittedSize.height
            )
        }
        .frame(
            width: previewCanvasSize.width,
            height: previewCanvasSize.height
        )
    }

    @ViewBuilder
    private func previewImage(
        _ image: UIImage,
        panel: PanelProfile?,
        fit: ImageFitMode?,
        size: CGSize
    ) -> some View {
        if let panel, let fit {
            ZStack(alignment: .topLeading) {
                Color.white

                if fit == .blur {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(
                            radius: max(
                                2,
                                min(size.width, size.height) / 16
                            )
                        )
                        .clipped()
                }

                let sourceWidth = image.size.width * image.scale
                let sourceHeight = image.size.height * image.scale
                let rect = fit.previewRect(
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    canvasWidth: size.width,
                    canvasHeight: size.height,
                    targetPixelWidth: Double(panel.width),
                    targetPixelHeight: Double(panel.height)
                )

                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(
                        width: max(0, rect.width),
                        height: max(0, rect.height)
                    )
                    .offset(x: rect.x, y: rect.y)
            }
            .frame(
                width: size.width,
                height: size.height,
                alignment: .topLeading
            )
            .clipped()
        } else {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }

    private func previewSize(for panel: PanelProfile?) -> CGSize {
        guard let panel else {
            return previewCanvasSize
        }

        let size = panel.fittedPreviewSize(
            maxWidth: previewCanvasSize.width,
            maxHeight: previewCanvasSize.height
        )
        return CGSize(width: size.width, height: size.height)
    }

    private func previewPanel(
        for deviceIDs: [String]
    ) -> PanelProfile? {
        deviceIDs.lazy.compactMap { id in
            model.displays.first(where: { $0.id == id })?.panel
        }.first
    }

    private func previewPanel(
        for item: HistoryItem
    ) -> PanelProfile? {
        if let panel = previewPanel(for: item.deviceIDs) {
            return panel
        }

        guard item.deviceIDs.isEmpty, item.source == "button" else {
            return nil
        }

        let matchingDisplays = model.displays.filter {
            $0.name.compare(
                item.label,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
        guard matchingDisplays.count == 1 else {
            return nil
        }
        return matchingDisplays[0].panel
    }

    private func compactStatus(
        label: String,
        symbol: String,
        color: Color
    ) -> some View {
        Image(systemName: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .frame(width: 24, height: 24)
            .background(.thinMaterial, in: Circle())
            .accessibilityLabel(Text(label))
            .allowsHitTesting(false)
    }

    private func expandedPhoto(_ thumbnail: UIImage) -> some View {
        FittedPreviewLayout(
            aspectRatio: thumbnail.size.width / thumbnail.size.height,
            maximumHeight: 420
        ) {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFit()
        }
        .frame(maxWidth: .infinity)
            .background(
                Color.primary.opacity(0.055),
                in: RoundedRectangle(
                    cornerRadius: 15,
                    style: .continuous
                )
            )
            .clipShape(
                RoundedRectangle(cornerRadius: 15, style: .continuous)
            )
            .accessibilityIdentifier("activity-photo-expanded")
            .accessibilityLabel("Expanded sent photo preview")
    }

    private func historyPreviewCaption(_ item: HistoryItem) -> String {
        if let fit = item.fit {
            return String(
                localized: "Source composition · \(fit.displayName) was applied per display"
            )
        }
        return String(localized: "Rendered dashboard composition")
    }

    private func historyStatusPresentation(
        _ item: HistoryItem
    ) -> HistoryStatusPresentation {
        let rawStatus = item.status.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let status = rawStatus.lowercased()

        return switch status {
        case "sent", "published", "succeeded":
            HistoryStatusPresentation(
                label: String(localized: "Published"),
                symbol: "checkmark.circle.fill",
                color: TesseraeTheme.accent
            )
        case "dispatched":
            HistoryStatusPresentation(
                label: String(localized: "Dispatched"),
                symbol: "checkmark.circle.fill",
                color: TesseraeTheme.accent
            )
        case "webhook_dispatched":
            HistoryStatusPresentation(
                label: String(localized: "Webhook Triggered"),
                symbol: "paperplane.fill",
                color: TesseraeTheme.accent
            )
        case "ha_dispatched":
            HistoryStatusPresentation(
                label: String(localized: "Home Assistant Triggered"),
                symbol: "house.fill",
                color: TesseraeTheme.accent
            )
        case "fetched":
            HistoryStatusPresentation(
                label: String(localized: "Refresh Requested"),
                symbol: "arrow.down.circle.fill",
                color: TesseraeTheme.accent
            )
        case "no_change":
            HistoryStatusPresentation(
                label: String(localized: "Already Current"),
                symbol: "checkmark.circle",
                color: TesseraeTheme.accent
            )
        case "passed":
            HistoryStatusPresentation(
                label: String(localized: "Passed"),
                symbol: "checkmark.circle.fill",
                color: TesseraeTheme.accent
            )
        case "quiet":
            HistoryStatusPresentation(
                label: String(localized: "Quiet"),
                symbol: "moon.fill",
                color: .indigo
            )
        case "busy":
            HistoryStatusPresentation(
                label: String(localized: "Busy"),
                symbol: "clock.fill",
                color: TesseraeTheme.ochre
            )
        case "held":
            HistoryStatusPresentation(
                label: String(localized: "Held"),
                symbol: "pause.circle.fill",
                color: TesseraeTheme.ochre
            )
        case "deduped":
            HistoryStatusPresentation(
                label: String(localized: "Duplicate Ignored"),
                symbol: "doc.on.doc.fill",
                color: .secondary
            )
        case "noop":
            HistoryStatusPresentation(
                label: String(localized: "No Action"),
                symbol: "minus.circle.fill",
                color: .secondary
            )
        case "superseded":
            HistoryStatusPresentation(
                label: String(localized: "Superseded"),
                symbol: "arrow.right.circle.fill",
                color: .secondary
            )
        case "unmapped":
            HistoryStatusPresentation(
                label: String(localized: "Unmapped"),
                symbol: "questionmark.circle.fill",
                color: TesseraeTheme.ochre
            )
        case "unbound":
            HistoryStatusPresentation(
                label: String(localized: "No Displays"),
                symbol: "rectangle.slash",
                color: TesseraeTheme.ochre
            )
        case "not_found":
            HistoryStatusPresentation(
                label: String(localized: "Not Found"),
                symbol: "magnifyingglass",
                color: TesseraeTheme.ochre
            )
        case "no_frame":
            HistoryStatusPresentation(
                label: String(localized: "No Current Frame"),
                symbol: "rectangle.slash",
                color: TesseraeTheme.ochre
            )
        case "no_target":
            HistoryStatusPresentation(
                label: String(localized: "No Action Here"),
                symbol: "scope",
                color: TesseraeTheme.ochre
            )
        case "stale":
            HistoryStatusPresentation(
                label: String(localized: "Outdated Frame"),
                symbol: "clock.fill",
                color: TesseraeTheme.ochre
            )
        case "blocked":
            HistoryStatusPresentation(
                label: String(localized: "Blocked"),
                symbol: "hand.raised.fill",
                color: TesseraeTheme.ochre
            )
        case "shifted":
            HistoryStatusPresentation(
                label: String(localized: "Adjusted"),
                symbol: "arrow.left.arrow.right.circle.fill",
                color: .indigo
            )
        case "fallback":
            HistoryStatusPresentation(
                label: String(localized: "Fallback Used"),
                symbol: "arrow.turn.down.right",
                color: .indigo
            )
        case "failed", "error":
            HistoryStatusPresentation(
                label: String(localized: "Failed"),
                symbol: "exclamationmark.triangle.fill",
                color: TesseraeTheme.terracotta
            )
        case "ha_failed":
            HistoryStatusPresentation(
                label: String(localized: "Home Assistant Failed"),
                symbol: "exclamationmark.triangle.fill",
                color: TesseraeTheme.terracotta
            )
        default:
            HistoryStatusPresentation(
                label: rawStatus.isEmpty
                    ? String(localized: "Unknown")
                    : rawStatus
                        .replacingOccurrences(of: "_", with: " ")
                        .capitalized,
                symbol: "questionmark.circle.fill",
                color: .secondary
            )
        }
    }

    private func fallbackTitle(_ kind: PushJobKind) -> String {
        switch kind {
        case .imagePush:
            String(localized: "Photo")
        case .imageURLPush:
            String(localized: "Image URL")
        case .webpagePush:
            String(localized: "Webpage")
        case .dashboardPush:
            String(localized: "Dashboard")
        case .historyResend:
            String(localized: "Resent item")
        case .lineupAction:
            String(localized: "Lineup")
        }
    }

    private func linkSourceLabel(_ kind: PushJobKind) -> String? {
        switch kind {
        case .imageURLPush, .webpagePush:
            fallbackTitle(kind)
        case .dashboardPush, .imagePush, .historyResend, .lineupAction:
            nil
        }
    }

    private func artworkSymbol(_ kind: PushJobKind) -> String {
        switch kind {
        case .imagePush:
            "photo"
        case .imageURLPush:
            "photo.badge.arrow.down"
        case .webpagePush:
            "safari"
        case .dashboardPush:
            "rectangle.grid.2x2"
        case .historyResend:
            "arrow.clockwise"
        case .lineupAction:
            "rectangle.3.group"
        }
    }

    private func statusLabel(_ job: PushJob) -> String {
        switch job.status {
        case .accepted: String(localized: "Queued")
        case .running: String(localized: "Sending")
        case .succeeded:
            job.result?.status == .quiet
                ? String(localized: "Quiet")
                : String(localized: "Published")
        case .failed: String(localized: "Failed")
        }
    }

    private func statusSymbol(_ job: PushJob) -> String {
        switch job.status {
        case .accepted: "clock"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded:
            job.result?.status == .quiet
                ? "moon.fill"
                : "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ job: PushJob) -> Color {
        switch job.status {
        case .accepted, .running: TesseraeTheme.ochre
        case .succeeded:
            job.result?.status == .quiet
                ? .indigo
                : TesseraeTheme.accent
        case .failed: TesseraeTheme.terracotta
        }
    }
}

private struct HistoryStatusPresentation {
    let label: String
    let symbol: String
    let color: Color
}

@MainActor
final class ActivityPhotoCache {
    static let shared = ActivityPhotoCache()

    private let images = NSCache<NSString, UIImage>()

    private init() {
        images.countLimit = 100
    }

    func image(for key: String, data: Data) -> UIImage? {
        let cacheKey = key as NSString
        if let cached = images.object(forKey: cacheKey) {
            return cached
        }

        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 800,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        else {
            return nil
        }

        let image = UIImage(cgImage: cgImage)
        images.setObject(image, forKey: cacheKey)
        return image
    }

    func remove(key: String) {
        images.removeObject(forKey: key as NSString)
    }

    func removeAll() {
        images.removeAllObjects()
    }
}
