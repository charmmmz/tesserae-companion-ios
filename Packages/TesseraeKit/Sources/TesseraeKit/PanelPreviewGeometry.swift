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
