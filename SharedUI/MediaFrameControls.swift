import SwiftUI

/// One inline control shared by server sends, Bluetooth sends, and the share extension.
struct MediaFrameControls: View {
    let session: MediaFrameSession
    var isSending = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if session.hasTimeline {
            VStack(alignment: .leading, spacing: 8) {
                if session.source?.kind == .livePhoto {
                    HStack {
                        Text(session.usesPrimaryImage ? String(localized: "Live Photo · Key Photo") : String(localized: "Live Photo"))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Button(session.isExpanded ? String(localized: "Hide Frames") : String(localized: "Choose Frame")) { session.toggleExpanded() }
                            .font(.footnote).frame(minHeight: 44)
                            .accessibilityIdentifier("media-choose-frame")
                    }
                }
                if session.isExpanded {
                    if session.isLoadingMovie {
                        ProgressView("Loading frames…")
                            .font(.footnote).frame(minHeight: 44)
                    } else if session.duration > 0 {
                        HStack(spacing: 10) {
                            if session.source?.kind == .livePhoto {
                                Button { session.restorePrimaryImage() } label: {
                                    if let data = session.source?.primaryImage.data, let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                            .frame(width: 44, height: 44).clipped()
                                            .overlay(alignment: .bottom) {
                                                Text("Key").font(.caption2)
                                                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge).lineLimit(1)
                                                    .foregroundStyle(.white).padding(.vertical, 2)
                                                    .frame(maxWidth: .infinity).background(.black.opacity(0.65))
                                            }
                                            .clipShape(.rect(cornerRadius: 6))
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Restore Key Photo")
                                .accessibilityAddTraits(session.usesPrimaryImage ? .isSelected : [])
                                .accessibilityIdentifier("media-restore-key-photo")
                            }
                            timeline
                        }
                    }
                }
                if let error = session.errorMessage {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(error).font(.footnote).foregroundStyle(TesseraeTheme.danger)
                        Button("Retry") { session.retry() }.font(.footnote).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("media-frame-error")
                }
            }
            .disabled(isSending)
            .tint(TesseraeTheme.accent)
        }
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
                .frame(width: proxy.size.width, height: 44).clipped()
                .clipShape(.rect(cornerRadius: 6))
                .accessibilityHidden(true)

                if !session.usesPrimaryImage || session.source?.kind == .video {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(TesseraeTheme.accent)
                        .frame(width: 3, height: 50)
                        .overlay { RoundedRectangle(cornerRadius: 1).strokeBorder(.white.opacity(0.9), lineWidth: 0.5) }
                        .offset(x: max(0, min(proxy.size.width - 3, proxy.size.width * session.position - 1.5)))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 50)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    session.select(position: value.location.x / max(1, proxy.size.width))
                }
                .onEnded { value in
                    session.select(position: value.location.x / max(1, proxy.size.width), immediately: true)
                })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Choose Frame")
            .accessibilityValue(session.usesPrimaryImage && session.source?.kind == .livePhoto
                ? String(localized: "Key Photo")
                : String(localized: "\((session.position * session.duration).formatted(.number.precision(.fractionLength(2)))) seconds"))
            .accessibilityAdjustableAction { direction in
                let step = min(0.01, 1 / max(1, session.duration * 30))
                session.select(position: session.position + (direction == .increment ? step : -step), immediately: true)
            }
            .accessibilityIdentifier("media-frame-timeline")
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 60 : 50)
    }
}
