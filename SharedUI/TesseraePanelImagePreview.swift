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
    // GestureState tracks cancellation only; its automatic reset must not move the image.
    @GestureState private var isFramingGestureActive = false
    @State private var framingInteraction = PhotoFramingInteraction()
    @State private var activeFramingContext: FramingPreviewContext?
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
        .onChange(of: isFramingGestureActive) { _, isActive in
            if !isActive {
                // A cancelled gesture has no onEnded callback. Keep its last visible crop.
                finishFramingInteraction()
            }
        }
        .onChange(of: framingContext) { _, _ in
            discardFramingInteraction()
        }
        .onDisappear {
            discardFramingInteraction()
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
                            !reduceMotion && !framingInteraction.isActive
                                && !isFramingGestureActive && autoFramingFeedback == .applied
                                ? .easeOut(duration: 0.18) : nil,
                            value: framing?.wrappedValue
                        )

                    if !dynamicTypeSize.isAccessibilitySize, let framing {
                        framingControls(framing: framing)
                            .padding(8)
                            .opacity(framingInteraction.controlsHidden ? 0 : 1)
                            .animation(
                                reduceMotion || framingInteraction.controlsHidden
                                    ? nil : .easeOut(duration: 0.18),
                                value: framingInteraction.controlsHidden
                            )
                            .allowsHitTesting(!framingInteraction.controlsHidden)
                            .accessibilityHidden(framingInteraction.controlsHidden)
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
                    let previewFraming = activeFramingContext == framingContext
                        ? framingInteraction.previewFraming ?? framing.wrappedValue
                        : framing.wrappedValue
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
                .foregroundStyle(TesseraeTheme.accentOnPaper)
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
        44
    }

    private var framingItemPadding: CGFloat {
        dynamicTypeSize.isAccessibilitySize ? 6 : 10
    }

    private var framingGestureHint: some View {
        Image(systemName: "hand.draw")
            .padding(.horizontal, framingItemPadding)
            .frame(minWidth: 44, minHeight: framingButtonSize)
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
                .frame(minWidth: 44, minHeight: framingButtonSize)
                .foregroundStyle(autoFramingIsApplied ? TesseraeTheme.success : Color.primary)
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
            .frame(minWidth: 44, minHeight: framingButtonSize)
            .accessibilityIdentifier("send-framing-zoom")

            Button {
                resetFraming(framing)
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .padding(.horizontal, framingItemPadding)
                    .frame(minWidth: 44, minHeight: framingButtonSize)
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
        withoutFramingAnimation {
            discardFramingInteraction()
            framing.wrappedValue = .centeredFill
        }
    }

    private func framingGesture(
        size: CGSize,
        image: UIImage?
    ) -> some Gesture {
        DragGesture(minimumDistance: prioritizesFramingGesture ? 0 : 1)
            .simultaneously(with: MagnifyGesture())
            .updating($isFramingGestureActive) { _, isActive, transaction in
                isActive = true
                transaction.disablesAnimations = true
            }
            .onChanged { value in
                guard framingEditingEnabled, let image, let framing else { return }
                withoutFramingAnimation {
                    if !framingInteraction.isActive {
                        onFramingInteraction?()
                        framingControlsRevealTask?.cancel()
                        framingControlsRevealTask = nil
                        activeFramingContext = framingContext
                        framingInteraction.begin(at: framing.wrappedValue)
                        previousGestureFraming = framing.wrappedValue
                        previousZoomBoundary = zoomBoundary(for: framing.wrappedValue.zoom)
                    }
                    framingInteraction.update(
                        translation: value.first?.translation,
                        magnification: value.second?.magnification,
                        geometry: framingGeometry(size: size, image: image)
                    )
                    if let previewFraming = framingInteraction.previewFraming {
                        updateFramingHaptics(with: previewFraming)
                    }
                }
            }
            .onEnded { value in
                guard framingInteraction.isActive else { return }
                guard activeFramingContext == framingContext, let image else {
                    discardFramingInteraction()
                    return
                }
                withoutFramingAnimation {
                    framingInteraction.update(
                        translation: value.first?.translation,
                        magnification: value.second?.magnification,
                        geometry: framingGeometry(size: size, image: image)
                    )
                    finishFramingInteraction()
                }
            }
    }

    private var framingContext: FramingPreviewContext {
        FramingPreviewContext(
            imageID: image.map(ObjectIdentifier.init),
            aspect: PanelAspectRatio(panel: panel),
            fit: fit,
            maximumZoom: maximumFramingZoom,
            isEditable: framingEditingEnabled && framing != nil
        )
    }

    private func framingGeometry(size: CGSize, image: UIImage) -> PhotoFramingInteraction.Geometry {
        .init(
            canvas: size,
            source: CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale),
            target: CGSize(width: panel.width, height: panel.height),
            maximumZoom: maximumFramingZoom
        )
    }

    private func withoutFramingAnimation(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction, update)
    }

    private func finishFramingInteraction() {
        guard framingInteraction.isActive else { return }
        guard activeFramingContext == framingContext, framingEditingEnabled, let framing else {
            discardFramingInteraction()
            return
        }
        withoutFramingAnimation {
            // Both sides of the handoff contain an absolute crop, never a crop plus an old delta.
            if let finalFraming = framingInteraction.end() {
                framing.wrappedValue = finalFraming
            }
            activeFramingContext = nil
            previousGestureFraming = nil
            previousZoomBoundary = nil
        }
        endFramingInteraction()
    }

    private func discardFramingInteraction() {
        framingControlsRevealTask?.cancel()
        framingControlsRevealTask = nil
        framingInteraction.reset()
        activeFramingContext = nil
        previousGestureFraming = nil
        previousZoomBoundary = nil
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
        let generation = framingInteraction.controlsRevealGeneration
        framingControlsRevealTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            framingInteraction.revealControls(generation: generation)
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

/// Per-gesture state stays local to the preview; the parent receives one crop at completion.
struct PhotoFramingInteraction {
    struct Geometry {
        let canvas: CGSize
        let source: CGSize
        let target: CGSize
        let maximumZoom: Double
    }

    private var translation = CGSize.zero
    private var magnification: CGFloat = 1
    private(set) var previewFraming: ImageFraming?
    private(set) var controlsHidden = false
    private(set) var controlsRevealGeneration = 0

    var isActive: Bool { previewFraming != nil }

    mutating func begin(at framing: ImageFraming) {
        // Local editing starts from the parent's crop, then consumes gesture deltas.
        previewFraming = framing
        translation = .zero
        magnification = 1
        controlsHidden = true
        controlsRevealGeneration += 1
    }

    mutating func update(translation: CGSize?, magnification: CGFloat?, geometry: Geometry) {
        guard let currentFraming = previewFraming else { return }
        // The drag and pinch can finish independently. A missing component is not a reset.
        let previousTranslation = self.translation
        let previousMagnification = self.magnification
        if let translation { self.translation = translation }
        if let magnification { self.magnification = magnification }
        // Consume overshoot at the edges/zoom limits, so reversing direction moves immediately.
        previewFraming = currentFraming.applyingPreviewGesture(
            translationX: Double(self.translation.width - previousTranslation.width),
            translationY: Double(self.translation.height - previousTranslation.height),
            magnification: Double(self.magnification / max(previousMagnification, 0.01)),
            canvasWidth: Double(geometry.canvas.width),
            canvasHeight: Double(geometry.canvas.height),
            sourceWidth: Double(geometry.source.width),
            sourceHeight: Double(geometry.source.height),
            targetWidth: Double(geometry.target.width),
            targetHeight: Double(geometry.target.height),
            maximumZoom: geometry.maximumZoom
        )
    }

    @discardableResult
    mutating func end() -> ImageFraming? {
        let finalFraming = previewFraming
        previewFraming = nil
        return finalFraming
    }

    mutating func revealControls(generation: Int) {
        guard !isActive, controlsRevealGeneration == generation else { return }
        controlsHidden = false
    }

    mutating func reset() {
        end()
        controlsHidden = false
        controlsRevealGeneration += 1
    }
}

private struct FramingPreviewContext: Equatable {
    let imageID: ObjectIdentifier?
    let aspect: PanelAspectRatio
    let fit: ImageFitMode
    let maximumZoom: Double
    let isEditable: Bool
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
