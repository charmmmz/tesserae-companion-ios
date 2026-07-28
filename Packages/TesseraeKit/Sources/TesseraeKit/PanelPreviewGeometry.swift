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
    /// Returns the image rectangle inside a fixed panel canvas using the same
    /// centered aspect-preserving geometry as Tesserae's `fit_to_panel`.
    ///
    /// For `fit`, the rectangle remains fully inside the canvas and the
    /// surrounding canvas is the server's white letterbox. For `fill`, the
    /// rectangle extends beyond one canvas axis and the caller clips it to the
    /// panel bounds, matching the server's centered crop.
    func previewRect(
        sourceWidth: Double,
        sourceHeight: Double,
        canvasWidth: Double,
        canvasHeight: Double
    ) -> PanelImagePreviewRect {
        guard
            sourceWidth > 0,
            sourceHeight > 0,
            canvasWidth > 0,
            canvasHeight > 0
        else {
            return .zero
        }

        let widthScale = canvasWidth / sourceWidth
        let heightScale = canvasHeight / sourceHeight
        let scale = switch self {
        case .fit:
            min(widthScale, heightScale)
        case .fill:
            max(widthScale, heightScale)
        }
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
