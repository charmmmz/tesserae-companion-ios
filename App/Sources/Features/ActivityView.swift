import SwiftUI
import TesseraeKit
import ImageIO
import UIKit

struct ActivityView: View {
    @Environment(AppModel.self) private var model
    @State private var expandedJobID: String?

    var body: some View {
        Group {
            if model.jobs.isEmpty {
                ContentUnavailableView(
                    "No Activity Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Dashboard and photo sends will appear here.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.jobs) { job in
                            activityCard(job)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .tesseraeScreenBackground()
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

                    if thumbnail != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(
                                .degrees(isExpanded ? 180 : 0)
                            )
                    }
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

    private func fallbackTitle(_ kind: PushJobKind) -> String {
        kind == .imagePush
            ? String(localized: "Photo")
            : String(localized: "Dashboard")
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
private final class ActivityPhotoCache {
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
            let cgImage = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [
                    kCGImageSourceShouldCache: true,
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
}
