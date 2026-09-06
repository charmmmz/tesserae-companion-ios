import SwiftUI
import TesseraeKit
import UIKit

/// A fixed Tesserae panel canvas that mirrors the server's five image-fit
/// modes. The image is laid out explicitly and clipped by the canvas, avoiding
/// SwiftUI's implicit `aspectRatio` sizing from escaping its parent.
struct TesseraePanelImagePreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let image: UIImage?
    let panel: PanelProfile
    let fit: ImageFitMode
    let maximumCanvasHeight: CGFloat
    let emptyTitle: String
    let accessibilityIdentifier: String
    let imageAccessibilityIdentifier: String
    let framing: Binding<ImageFraming>?
    let maximumFramingZoom: Double
    let onCanvasTap: (() -> Void)?
    let prioritizesFramingGesture: Bool
    let framingEditingEnabled: Bool
    let onAutoFrame: (() -> Void)?
    let isAutoFraming: Bool
    let autoFramingFeedback: PhotoFramingSession.Feedback?
    let onFramingInteraction: (() -> Void)?
    @GestureState private var framingGestureState = FramingGestureState()
    @State private var isFramingGestureActive = false
    @State private var framingControlsRevealTask: Task<Void, Never>?
    @State private var previousGestureFraming: ImageFraming?
    @State private var previousZoomBoundary: FramingZoomBoundary?
    @State private var hapticEvent = TesseraeHapticEvent()

    init(
        image: UIImage?,
        panel: PanelProfile,
        fit: ImageFitMode,
        maximumCanvasHeight: CGFloat,
        emptyTitle: String,
        accessibilityIdentifier: String,
        imageAccessibilityIdentifier: String,
        framing: Binding<ImageFraming>? = nil,
        maximumFramingZoom: Double = 1,
        onCanvasTap: (() -> Void)? = nil,
        prioritizesFramingGesture: Bool = false,
        framingEditingEnabled: Bool = true,
        onAutoFrame: (() -> Void)? = nil,
        isAutoFraming: Bool = false,
        autoFramingFeedback: PhotoFramingSession.Feedback? = nil,
        onFramingInteraction: (() -> Void)? = nil
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
        self.onCanvasTap = onCanvasTap
        self.prioritizesFramingGesture = prioritizesFramingGesture
        self.framingEditingEnabled = framingEditingEnabled
        self.onAutoFrame = onAutoFrame
        self.isAutoFraming = isAutoFraming
        self.autoFramingFeedback = autoFramingFeedback
        self.onFramingInteraction = onFramingInteraction
    }

    var body: some View {
        VStack(spacing: 12) {
            previewPanel
            if dynamicTypeSize.isAccessibilitySize, let framing {
                framingControls(framing: framing)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
        .tesseraeHapticFeedback(trigger: hapticEvent)
        .onDisappear {
            framingControlsRevealTask?.cancel()
        }
    }

    private var previewPanel: some View {
        PanelAspectLayout(
            aspectRatio: CGFloat(max(panel.width, 1))
                / CGFloat(max(panel.height, 1)),
            maximumHeight: maximumCanvasHeight
        ) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    panelCanvas(size: proxy.size)
                        .animation(
                            !reduceMotion && autoFramingFeedback == .applied
                                ? .easeOut(duration: 0.18) : nil,
                            value: framing?.wrappedValue
                        )

                    if !dynamicTypeSize.isAccessibilitySize, let framing {
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
    }

    @ViewBuilder
    private func panelCanvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white

            if let image {
                if let framing {
                    let sourceWidth = image.size.width * image.scale
                    let sourceHeight = image.size.height * image.scale
                    let previewFraming = framing.wrappedValue
                        .applyingPreviewGesture(
                            translationX: Double(
                                framingGestureState.translation.width
                            ),
                            translationY: Double(
                                framingGestureState.translation.height
                            ),
                            magnification: Double(
                                framingGestureState.magnification
                            ),
                            canvasWidth: Double(size.width),
                            canvasHeight: Double(size.height),
                            sourceWidth: Double(sourceWidth),
                            sourceHeight: Double(sourceHeight),
                            targetWidth: Double(panel.width),
                            targetHeight: Double(panel.height),
                            maximumZoom: maximumFramingZoom
                        )
                    let rect = previewFraming.framedPreviewRect(
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
        .onTapGesture {
            onCanvasTap?()
        }
        .gesture(
            framingGesture(size: size, image: image),
            including: framingGestureMask(prioritized: false, image: image)
        )
        .highPriorityGesture(
            framingGesture(size: size, image: image),
            including: framingGestureMask(prioritized: true, image: image)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display image preview")
        .accessibilityIdentifier(imageAccessibilityIdentifier)
    }

    private func framingControls(
        framing: Binding<ImageFraming>
    ) -> some View {
        framingAdjustmentControls(framing: framing)
            .disabled(!framingEditingEnabled)
            .font(.caption)
            .padding(.horizontal, 5)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("send-framing-controls")
    }

    private var framingButtonSize: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 44 : 32
    }

    private var framingItemPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 10
    }

    private var framingGestureHint: some View {
        Image(systemName: "hand.draw")
            .padding(.horizontal, framingItemPadding)
            .frame(minHeight: framingButtonSize)
            .accessibilityLabel("Drag · Pinch to zoom")
            .accessibilityIdentifier("send-framing-hint")
    }

    private var autoFrameButton: some View {
        Button {
            onAutoFrame?()
        } label: {
            Image(systemName: "wand.and.stars")
                .opacity(isAutoFraming ? 0 : 1)
                .overlay {
                    if isAutoFraming {
                        ProgressView().controlSize(.mini)
                    }
                }
                .padding(.horizontal, framingItemPadding)
                .frame(minHeight: framingButtonSize)
                .foregroundStyle(autoFramingIsApplied ? Color.accentColor : Color.primary)
                .overlay(alignment: .topTrailing) {
                    if !isAutoFraming, !autoFramingIsApplied, autoFramingFeedback != nil {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 13 : 10, weight: .bold))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.secondary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAutoFraming)
        .accessibilityLabel("Auto Zoom")
        .accessibilityValue(isAutoFraming ? String(localized: "Analyzing photo") : autoFramingFeedback?.text ?? String(localized: "Manual"))
        .accessibilityHint("Adjust the photo for the current display aspect ratio.")
        .accessibilityIdentifier("send-auto-framing")
        .contextMenu {
            if let autoFramingFeedback {
                Text(autoFramingFeedback.explanation)
            }
            Button("Auto Zoom", systemImage: "wand.and.stars") { onAutoFrame?() }
                .disabled(isAutoFraming || !framingEditingEnabled)
        }
    }

    private var autoFramingIsApplied: Bool {
        autoFramingFeedback == .applied || autoFramingFeedback == .unchanged
    }

    private func framingAdjustmentControls(framing: Binding<ImageFraming>)
        -> some View
    {
        HStack(spacing: 0) {
            framingGestureHint

            if onAutoFrame != nil {
                autoFrameButton
            }

            Text(
                framing.wrappedValue.zoom.formatted(
                    .number.precision(.fractionLength(1...2))
                ) + "×"
            )
            .monospacedDigit()
            .fontWeight(.semibold)
            .fixedSize()
            .padding(.horizontal, framingItemPadding)
            .frame(minHeight: framingButtonSize)
            .accessibilityIdentifier("send-framing-zoom")

            Button {
                resetFraming(framing)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .padding(.horizontal, framingItemPadding)
                    .frame(minHeight: framingButtonSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(framing.wrappedValue == .centeredFill)
            .accessibilityLabel("Reset Framing")
            .accessibilityIdentifier("send-framing-reset")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func resetFraming(_ framing: Binding<ImageFraming>) {
        onFramingInteraction?()
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
        DragGesture(minimumDistance: prioritizesFramingGesture ? 0 : 1)
            .simultaneously(with: MagnificationGesture())
            .updating($framingGestureState) { value, state, _ in
                state = FramingGestureState(
                    translation: value.first?.translation ?? .zero,
                    magnification: value.second ?? 1
                )
            }
            .onChanged { value in
                guard framingEditingEnabled, let image, let framing else { return }
                let previewFraming = framing.wrappedValue.applyingPreviewGesture(
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
                if !isFramingGestureActive {
                    onFramingInteraction?()
                    framingControlsRevealTask?.cancel()
                    framingControlsRevealTask = nil
                    isFramingGestureActive = true
                    previousGestureFraming = framing.wrappedValue
                    previousZoomBoundary = zoomBoundary(
                        for: framing.wrappedValue.zoom
                    )
                }
                updateFramingHaptics(with: previewFraming)
            }
            .onEnded { value in
                guard framingEditingEnabled, let image, let framing else { return }
                let translation = value.first?.translation ?? .zero
                let magnification = value.second ?? 1
                framing.wrappedValue = framing.wrappedValue
                    .applyingPreviewGesture(
                        translationX: Double(
                            translation.width
                        ),
                        translationY: Double(
                            translation.height
                        ),
                        magnification: Double(magnification),
                        canvasWidth: Double(size.width),
                        canvasHeight: Double(size.height),
                        sourceWidth: Double(image.size.width * image.scale),
                        sourceHeight: Double(image.size.height * image.scale),
                        targetWidth: Double(panel.width),
                        targetHeight: Double(panel.height),
                        maximumZoom: maximumFramingZoom
                    )
                previousGestureFraming = nil
                previousZoomBoundary = nil
                endFramingInteraction()
            }
    }

    private func framingGestureMask(
        prioritized: Bool,
        image: UIImage?
    ) -> GestureMask {
        guard framingEditingEnabled, framing != nil, image != nil,
              prioritizesFramingGesture == prioritized else {
            return .none
        }
        return .all
    }

    private func endFramingInteraction() {
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

    private func updateFramingHaptics(with framing: ImageFraming) {
        guard let previousGestureFraming else { return }

        let crossedAlignment = crossedCenter(
            from: previousGestureFraming.focusX,
            to: framing.focusX
        ) || crossedCenter(
            from: previousGestureFraming.focusY,
            to: framing.focusY
        )
        let boundary = zoomBoundary(for: framing.zoom)

        if crossedAlignment {
            hapticEvent.trigger(.alignment)
        } else if boundary != nil, boundary != previousZoomBoundary {
            hapticEvent.trigger(.lightImpact)
        }

        self.previousGestureFraming = framing
        previousZoomBoundary = boundary
    }

    private func crossedCenter(from oldValue: Double, to newValue: Double) -> Bool {
        (oldValue < 0.5 && newValue >= 0.5)
            || (oldValue > 0.5 && newValue <= 0.5)
    }

    private func zoomBoundary(for zoom: Double) -> FramingZoomBoundary? {
        if abs(zoom - 1) < 0.000_1 {
            return .minimum
        }
        if maximumFramingZoom > 1,
           abs(zoom - maximumFramingZoom) < 0.000_1
        {
            return .maximum
        }
        return nil
    }
}

private struct FramingGestureState {
    var translation = CGSize.zero
    var magnification: CGFloat = 1
}

private enum FramingZoomBoundary {
    case minimum
    case maximum
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
