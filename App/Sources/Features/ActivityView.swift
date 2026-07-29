import SwiftUI
import TesseraeKit
import ImageIO
import UIKit

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedQueuedImageID: String?
    @State private var expandedJobID: String?
    @State private var expandedHistoryID: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(model.queuedImageRequests) { request in
                    queuedImageCard(request)
                }
                ForEach(visibleJobs) { job in
                    activityCard(job)
                }
                ForEach(model.historyItems) { item in
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
                && visibleJobs.isEmpty
                && model.historyItems.isEmpty
            {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Dashboard and photo sends will appear here.")
                )
            }
        }
        .refreshable {
            model.startActivityRefresh()
        }
        .tesseraeScreenBackground()
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
                HStack(alignment: .center, spacing: 13) {
                    queuedImageArtwork(thumbnail)

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

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 12) {
                        Label(
                            queuedImageStatusLabel(request),
                            systemImage: queuedImageStatusSymbol(request)
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(queuedImageStatusColor(request))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(
                            queuedImageStatusColor(request).opacity(0.11),
                            in: Capsule()
                        )
                    }
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

    @ViewBuilder
    private func queuedImageArtwork(_ thumbnail: UIImage?) -> some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 88)
                .clipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .accessibilityLabel("Queued photo preview")
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TesseraeTheme.ochre.opacity(0.11))
                Image(systemName: "photo.badge.clock")
                    .font(.title2)
                    .foregroundStyle(TesseraeTheme.ochre)
            }
            .frame(width: 58, height: 64)
            .accessibilityHidden(true)
        }
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
            HStack(alignment: .center, spacing: 13) {
                leadingArtwork(
                    job,
                    thumbnail: thumbnail
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(job.label ?? fallbackTitle(job.kind))
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(model.displayNames(for: job.targetDeviceIDs))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)

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

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 12) {
                    Label(
                        statusLabel(job),
                        systemImage: statusSymbol(job)
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor(job))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        statusColor(job).opacity(0.11),
                        in: Capsule()
                    )
                }
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

        return VStack(alignment: .leading, spacing: isExpanded ? 14 : 10) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    guard preview != nil else { return }
                    withAnimation(.smooth(duration: 0.28)) {
                        expandedHistoryID = isExpanded ? nil : item.id
                    }
                } label: {
                    HStack(alignment: .center, spacing: 13) {
                        historyArtwork(item, preview: preview)

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
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("history-card-\(item.id)")

                VStack(alignment: .trailing, spacing: 10) {
                    Label(
                        historyStatusLabel(item),
                        systemImage: historyStatusSymbol(item)
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(historyStatusColor(item))
                    .frame(width: 112)
                    .padding(.vertical, 6)
                    .background(
                        historyStatusColor(item).opacity(0.11),
                        in: Capsule()
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(
                        "history-status-\(item.id)"
                    )

                    if item.resendable {
                        Button {
                            Task { await model.resend(item) }
                        } label: {
                            HStack(spacing: 5) {
                                if isResending {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                                Text("Resend")
                            }
                            .font(.caption.weight(.semibold))
                            .frame(width: 112)
                            .padding(.vertical, 6)
                            .background(
                                TesseraeTheme.accent.opacity(0.11),
                                in: Capsule()
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(TesseraeTheme.accent)
                        .disabled(isResending)
                        .accessibilityLabel(
                            isResending ? "Resending…" : "Resend"
                        )
                        .accessibilityIdentifier(
                            "history-resend-\(item.id)"
                        )
                    }
                }
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
        if let preview {
            Image(uiImage: preview)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 88)
                .clipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .accessibilityLabel("Sent composition preview")
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TesseraeTheme.accent.opacity(0.11))
                Image(
                    systemName: item.fit == nil
                        ? "rectangle.grid.2x2"
                        : "photo"
                )
                .font(.title2)
                .foregroundStyle(TesseraeTheme.accent)
            }
            .frame(width: 58, height: 64)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func leadingArtwork(
        _ job: PushJob,
        thumbnail: UIImage?
    ) -> some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 88)
                .clipShape(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                }
                .accessibilityIdentifier("activity-photo-thumbnail")
                .accessibilityLabel("Sent photo preview")
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TesseraeTheme.accent.opacity(0.11))
                Image(
                    systemName: job.kind == .imagePush
                        ? "photo"
                        : "rectangle.grid.2x2"
                )
                .font(.title2)
                .foregroundStyle(TesseraeTheme.accent)
            }
            .frame(width: 58, height: 64)
            .accessibilityHidden(true)
        }
    }

    private func expandedPhoto(_ thumbnail: UIImage) -> some View {
        ActivityFittedPhotoLayout(
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

    private func historyStatusLabel(_ item: HistoryItem) -> String {
        switch item.status {
        case "sent", "published", "succeeded":
            String(localized: "Published")
        case "quiet":
            String(localized: "Quiet")
        case "failed", "error":
            String(localized: "Failed")
        default:
            item.status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func historyStatusSymbol(_ item: HistoryItem) -> String {
        switch item.status {
        case "sent", "published", "succeeded":
            "checkmark.circle.fill"
        case "quiet":
            "moon.fill"
        case "failed", "error":
            "exclamationmark.triangle.fill"
        default:
            "clock"
        }
    }

    private func historyStatusColor(_ item: HistoryItem) -> Color {
        switch item.status {
        case "sent", "published", "succeeded":
            TesseraeTheme.accent
        case "quiet":
            .indigo
        case "failed", "error":
            TesseraeTheme.terracotta
        default:
            TesseraeTheme.ochre
        }
    }

    private func fallbackTitle(_ kind: PushJobKind) -> String {
        switch kind {
        case .imagePush:
            String(localized: "Photo")
        case .dashboardPush:
            String(localized: "Dashboard")
        case .historyResend:
            String(localized: "Resent item")
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

private struct ActivityFittedPhotoLayout: Layout {
    let aspectRatio: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }

        let fallback = subview.sizeThatFits(.unspecified)
        let width = proposal.width ?? fallback.width
        let safeRatio = max(aspectRatio, 0.01)
        return CGSize(
            width: width,
            height: min(width / safeRatio, maximumHeight)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }
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
