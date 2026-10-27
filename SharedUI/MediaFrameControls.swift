import SwiftUI

/// One inline control shared by server sends, Bluetooth sends, and the share extension.
struct MediaFrameControls: View {
    let session: MediaFrameSession
    var isSending = false
    var onChooseLivePhoto: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @GestureState private var isDragging = false

    var body: some View {
        if session.hasTimeline {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if session.source?.kind == .livePhoto {
                        keyPhoto
                    }
                    if session.isLoadingMovie {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .accessibilityLabel("Loading frames…")
                    } else if session.duration > 0 {
                        timeline
                    } else if offersReselection, session.errorMessage != nil, let onChooseLivePhoto {
                        Button("Choose Live Photo", systemImage: "photo") { onChooseLivePhoto() }
                            .font(.footnote)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .accessibilityIdentifier("media-reselect-live-photo")
                    }
                }
                if let error = session.errorMessage {
                    Group {
                        if offersReselection {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(error).font(.footnote).foregroundStyle(TesseraeTheme.danger)
                                Button("Retry") { session.retry() }.font(.footnote).frame(minHeight: 44)
                            }
                        }
                    }
                    .accessibilityIdentifier("media-frame-error")
                }
            }
            .disabled(isSending)
            .tint(TesseraeTheme.accent)
        }
    }

    private var offersReselection: Bool {
        session.source?.kind == .livePhoto && session.duration == 0 && onChooseLivePhoto != nil
    }

    private var keyPhoto: some View {
        Button { session.restorePrimaryImage() } label: {
            if let data = session.source?.primaryImage.data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: 52, height: 52).clipped()
                    .overlay(alignment: .bottom) {
                        Text("Key").font(.caption2)
                            .dynamicTypeSize(...DynamicTypeSize.xxxLarge).lineLimit(1)
                            .foregroundStyle(.white).padding(.vertical, 2)
                            .frame(maxWidth: .infinity).background(.black.opacity(0.65))
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(keyPhotoIsSelected ? TesseraeTheme.accent : .clear, lineWidth: 2)
                    }
                    .overlay(alignment: .topTrailing) {
                        if keyPhotoIsSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white, TesseraeTheme.accent)
                                .padding(3)
                        }
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Restore Key Photo")
        .accessibilityAddTraits(keyPhotoIsSelected ? .isSelected : [])
        .accessibilityIdentifier("media-restore-key-photo")
    }

    private var keyPhotoIsSelected: Bool {
        session.usesPrimaryImage && !session.isRenderingFrame
    }

    private var timeline: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                HStack(spacing: 1) {
                    if session.thumbnails.isEmpty, let data = session.source?.primaryImage.data,
                       let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().accessibilityHidden(true)
                    } else {
                        ForEach(session.thumbnails) { frame in
                            Image(uiImage: frame.image).resizable().scaledToFill()
                                .frame(width: max(1, (proxy.size.width - CGFloat(session.thumbnails.count - 1)) / CGFloat(session.thumbnails.count)))
                                .clipped().accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: proxy.size.width, height: 52).clipped()
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)

                if !session.usesPrimaryImage || session.isRenderingFrame || session.source?.kind == .video {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(TesseraeTheme.accent)
                        .frame(width: 3, height: 58)
                        .overlay { RoundedRectangle(cornerRadius: 1).strokeBorder(.white.opacity(0.9), lineWidth: 0.5) }
                        .offset(x: max(0, min(proxy.size.width - 3, proxy.size.width * session.position - 1.5)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 58)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .updating($isDragging) { _, dragging, _ in dragging = true }
                .onChanged { value in
                    session.select(position: value.location.x / max(1, proxy.size.width))
                }
                .onEnded { value in
                    session.select(position: value.location.x / max(1, proxy.size.width), immediately: true)
                })
            .onChange(of: isDragging) { _, dragging in
                // GestureState also resets when a drag is interrupted.
                if !dragging, session.isScrubbing {
                    session.select(position: session.position, immediately: true)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Choose Frame")
            .accessibilityValue(session.usesPrimaryImage && !session.isRenderingFrame && session.source?.kind == .livePhoto
                ? String(localized: "Key Photo")
                : String(localized: "\((session.position * session.duration).formatted(.number.precision(.fractionLength(2)))) seconds"))
            .accessibilityAdjustableAction { direction in
                let step = min(0.01, 1 / max(1, session.duration * 30))
                session.select(position: session.position + (direction == .increment ? step : -step), immediately: true)
            }
            .accessibilityIdentifier("media-frame-timeline")
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 60 : 58)
    }
}
