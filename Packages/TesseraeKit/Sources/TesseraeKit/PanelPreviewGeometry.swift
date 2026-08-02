public struct PanelPreviewSize: Equatable, Hashable, Sendable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = PanelPreviewSize(width: 0, height: 0)
}

public struct PanelImagePreviewRect: Equatable, Hashable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let zero = PanelImagePreviewRect(
        x: 0,
        y: 0,
        width: 0,
        height: 0
    )
}

public extension PanelProfile {
    /// Fits the panel inside a preview canvas without changing its native
    /// aspect ratio. The Companion contract guarantees positive panel
    /// dimensions, but the fallback keeps malformed downstream data from
    /// producing an invalid SwiftUI frame.
    func fittedPreviewSize(maxWidth: Double, maxHeight: Double) -> PanelPreviewSize {
        guard maxWidth > 0, maxHeight > 0 else {
            return .zero
        }

        let panelWidth = Double(max(width, 1))
        let panelHeight = Double(max(height, 1))
        let scale = min(maxWidth / panelWidth, maxHeight / panelHeight)

        return PanelPreviewSize(
            width: panelWidth * scale,
            height: panelHeight * scale
        )
    }
}

public extension ImageFitMode {
    /// Returns the foreground image rectangle inside a fixed panel canvas using
    /// the same geometry as Tesserae's `fit_to_panel`.
    ///
    /// `blur` uses the `fit` foreground rectangle; callers paint the blurred
    /// `fill` copy behind it. `center` needs the target panel's pixel dimensions
    /// because its defining behavior is no scaling in panel-pixel space.
    func previewRect(
        sourceWidth: Double,
        sourceHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        targetPixelWidth: Double? = nil,
        targetPixelHeight: Double? = nil
    ) -> PanelImagePreviewRect {
        guard
            sourceWidth > 0,
            sourceHeight > 0,
            canvasWidth > 0,
            canvasHeight > 0
        else {
            return .zero
        }

        if self == .stretch {
            return PanelImagePreviewRect(
                x: 0,
                y: 0,
                width: canvasWidth,
                height: canvasHeight
            )
        }

        if self == .center {
            let panelWidth = max(targetPixelWidth ?? canvasWidth, 1)
            let panelHeight = max(targetPixelHeight ?? canvasHeight, 1)
            let width = sourceWidth * canvasWidth / panelWidth
            let height = sourceHeight * canvasHeight / panelHeight
            return PanelImagePreviewRect(
                x: (canvasWidth - width) / 2,
                y: (canvasHeight - height) / 2,
                width: width,
                height: height
            )
        }

        let widthScale = canvasWidth / sourceWidth
        let heightScale = canvasHeight / sourceHeight
        let scale = self == .fill
            ? max(widthScale, heightScale)
            : min(widthScale, heightScale)
        let width = sourceWidth * scale
        let height = sourceHeight * scale

        return PanelImagePreviewRect(
            x: (canvasWidth - width) / 2,
            y: (canvasHeight - height) / 2,
            width: width,
            height: height
        )
    }
}

public extension ImageFraming {
    static var centeredFill: ImageFraming {
        ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 1)
    }

    /// Returns the full source-image rectangle needed to display this framing
    /// inside one panel-shaped preview canvas.
    func framedPreviewRect(
        sourceWidth: Double,
        sourceHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        targetWidth: Double,
        targetHeight: Double
    ) -> PanelImagePreviewRect {
        guard canvasWidth > 0, canvasHeight > 0 else {
            return .zero
        }
        let crop = resolvedCrop(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )
        guard crop.width > 0, crop.height > 0 else {
            return .zero
        }
        let width = canvasWidth / crop.width
        let height = canvasHeight / crop.height
        return PanelImagePreviewRect(
            x: -crop.x * width,
            y: -crop.y * height,
            width: width,
            height: height
        )
    }

    /// Maps one drag/pinch gesture from panel-preview points back into the
    /// target-independent focus + zoom intent sent to Tesserae.
    func applyingPreviewGesture(
        translationX: Double,
        translationY: Double,
        magnification: Double,
        canvasWidth: Double,
        canvasHeight: Double,
        sourceWidth: Double,
        sourceHeight: Double,
        targetWidth: Double,
        targetHeight: Double,
        maximumZoom: Double
    ) -> ImageFraming {
        let boundedMaximumZoom = max(maximumZoom, 1)
        let nextZoom = min(
            max(zoom * max(magnification, 0.01), 1),
            boundedMaximumZoom
        )
        let zoomed = ImageFraming(
            focusX: min(max(focusX, 0), 1),
            focusY: min(max(focusY, 0), 1),
            zoom: nextZoom
        )
        let crop = zoomed.resolvedCrop(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )

        guard
            canvasWidth > 0,
            canvasHeight > 0,
            crop.width > 0,
            crop.height > 0
        else {
            return zoomed
        }

        let fullPreviewWidth = canvasWidth / crop.width
        let fullPreviewHeight = canvasHeight / crop.height
        let hasTranslation = abs(translationX) > 0.001
            || abs(translationY) > 0.001
        guard hasTranslation else {
            return zoomed
        }

        let translatedFocusX = zoomed.focusX
            - translationX / fullPreviewWidth
        let translatedFocusY = zoomed.focusY
            - translationY / fullPreviewHeight
        return ImageFraming(
            focusX: min(
                max(translatedFocusX, crop.width / 2),
                1 - crop.width / 2
            ),
            focusY: min(
                max(translatedFocusY, crop.height / 2),
                1 - crop.height / 2
            ),
            zoom: nextZoom
        )
    }
}
