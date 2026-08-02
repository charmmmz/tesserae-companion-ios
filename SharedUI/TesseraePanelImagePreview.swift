import SwiftUI
import TesseraeKit
import UIKit

/// A fixed Tesserae panel canvas that mirrors the server's five image-fit
/// modes. The image is laid out explicitly and clipped by the canvas, avoiding
/// SwiftUI's implicit `aspectRatio` sizing from escaping its parent.
struct TesseraePanelImagePreview: View {
    let image: UIImage?
    let panel: PanelProfile
    let fit: ImageFitMode
    let maximumCanvasHeight: CGFloat
    let emptyTitle: String
    let accessibilityIdentifier: String
    let imageAccessibilityIdentifier: String
    let framing: Binding<ImageFraming>?
    let maximumFramingZoom: Double
    @State private var gestureStartFraming: ImageFraming?
    @State private var isFramingGestureActive = false
    @State private var framingControlsRevealTask: Task<Void, Never>?

    init(
        image: UIImage?,
        panel: PanelProfile,
        fit: ImageFitMode,
        maximumCanvasHeight: CGFloat,
        emptyTitle: String,
        accessibilityIdentifier: String,
        imageAccessibilityIdentifier: String,
        framing: Binding<ImageFraming>? = nil,
        maximumFramingZoom: Double = 1
    ) {
        self.image = image
        self.panel = panel
        self.fit = fit
        self.maximumCanvasHeight = maximumCanvasHeight
        self.emptyTitle = emptyTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.imageAccessibilityIdentifier = imageAccessibilityIdentifier
        self.framing = framing
        self.maximumFramingZoom = maximumFramingZoom
    }

    var body: some View {
        PanelAspectLayout(
            aspectRatio: CGFloat(max(panel.width, 1))
                / CGFloat(max(panel.height, 1)),
            maximumHeight: maximumCanvasHeight
        ) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    panelCanvas(size: proxy.size)

                    if let framing {
                        framingControls(framing: framing)
                            .padding(8)
                            .opacity(isFramingGestureActive ? 0 : 1)
                            .allowsHitTesting(!isFramingGestureActive)
                            .accessibilityHidden(isFramingGestureActive)
                    }
                }
            }
        }
        .padding(7)
        .background(
            Color.black.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .onDisappear {
            framingControlsRevealTask?.cancel()
        }
    }

    @ViewBuilder
    private func panelCanvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white

            if let image {
                if let framing {
                    let sourceWidth = image.size.width * image.scale
                    let sourceHeight = image.size.height * image.scale
                    let rect = framing.wrappedValue.framedPreviewRect(
                        sourceWidth: sourceWidth,
                        sourceHeight: sourceHeight,
                        canvasWidth: size.width,
                        canvasHeight: size.height,
                        targetWidth: Double(panel.width),
                        targetHeight: Double(panel.height)
                    )

                    Image(uiImage: image)
                        .resizable()
                        .frame(
                            width: max(0, rect.width),
                            height: max(0, rect.height)
                        )
                        .offset(x: rect.x, y: rect.y)
                } else {
                    if fit == .blur {
                        Image(uiImage: image)
                            .resizable()
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
                        .frame(
                            width: max(0, rect.width),
                            height: max(0, rect.height)
                        )
                        .offset(x: rect.x, y: rect.y)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 36))
                    Text(emptyTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(TesseraeTheme.accent)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .frame(
            width: size.width,
            height: size.height,
            alignment: .topLeading
        )
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .gesture(
            framingGesture(size: size, image: image),
            including: framing == nil || image == nil ? .none : .all
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display image preview")
        .accessibilityIdentifier(imageAccessibilityIdentifier)
    }

    private func framingControls(
        framing: Binding<ImageFraming>
    ) -> some View {
        HStack(spacing: 8) {
            Label {
                ViewThatFits(in: .horizontal) {
                    Text("Drag · Pinch to zoom")
                    Text("Adjust")
                }
            } icon: {
                Image(systemName: "hand.draw")
            }
                .lineLimit(1)
                .accessibilityIdentifier("send-framing-hint")

            Spacer(minLength: 2)

            Text(
                framing.wrappedValue.zoom.formatted(
                    .number.precision(.fractionLength(1...2))
                ) + "×"
            )
            .monospacedDigit()
            .fontWeight(.semibold)
            .accessibilityIdentifier("send-framing-zoom")

            Button {
                resetFraming(framing)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(framing.wrappedValue == .centeredFill)
            .accessibilityLabel("Reset Framing")
            .accessibilityIdentifier("send-framing-reset")
        }
        .font(.caption)
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }

    private func resetFraming(_ framing: Binding<ImageFraming>) {
        gestureStartFraming = nil
        framingControlsRevealTask?.cancel()
        framingControlsRevealTask = nil
        framing.wrappedValue = .centeredFill
        withAnimation(.easeOut(duration: 0.18)) {
            isFramingGestureActive = false
        }
    }

    private func framingGesture(
        size: CGSize,
        image: UIImage?
    ) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .simultaneously(with: MagnificationGesture())
            .onChanged { value in
                guard let image, let framing else { return }
                let start = gestureStartFraming ?? framing.wrappedValue
                if gestureStartFraming == nil {
                    framingControlsRevealTask?.cancel()
                    framingControlsRevealTask = nil
                    gestureStartFraming = start
                    isFramingGestureActive = true
                }
                framing.wrappedValue = start.applyingPreviewGesture(
                    translationX: Double(value.first?.translation.width ?? 0),
                    translationY: Double(value.first?.translation.height ?? 0),
                    magnification: Double(value.second ?? 1),
                    canvasWidth: Double(size.width),
                    canvasHeight: Double(size.height),
                    sourceWidth: Double(image.size.width * image.scale),
                    sourceHeight: Double(image.size.height * image.scale),
                    targetWidth: Double(panel.width),
                    targetHeight: Double(panel.height),
                    maximumZoom: maximumFramingZoom
                )
            }
            .onEnded { _ in
                gestureStartFraming = nil
                framingControlsRevealTask?.cancel()
                framingControlsRevealTask = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        isFramingGestureActive = false
                    }
                    framingControlsRevealTask = nil
                }
            }
    }
}

private struct PanelAspectLayout: Layout {
    let aspectRatio: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let safeRatio = aspectRatio.isFinite && aspectRatio > 0
            ? aspectRatio
            : 1
        let proposedWidth = proposal.width ?? maximumHeight * safeRatio
        let availableWidth = proposedWidth.isFinite
            ? max(1, proposedWidth)
            : maximumHeight * safeRatio
        let height = min(maximumHeight, availableWidth / safeRatio)
        return CGSize(width: height * safeRatio, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }
}
