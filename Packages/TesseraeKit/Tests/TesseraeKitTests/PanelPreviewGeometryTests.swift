import XCTest
@testable import TesseraeKit

final class PanelPreviewGeometryTests: XCTestCase {
    func testPortraitPanelFitsByHeightAndPreservesAspectRatio() {
        let panel = PanelProfile(
            width: 1_200,
            height: 1_600,
            gamut: "spectra6",
            orientation: "portrait"
        )

        let size = panel.fittedPreviewSize(maxWidth: 320, maxHeight: 180)

        XCTAssertEqual(size.width, 135, accuracy: 0.001)
        XCTAssertEqual(size.height, 180, accuracy: 0.001)
        XCTAssertEqual(size.width / size.height, 0.75, accuracy: 0.001)
    }

    func testLandscapePanelFitsByHeightAndPreservesAspectRatio() {
        let panel = PanelProfile(
            width: 1_600,
            height: 1_200,
            gamut: "spectra6",
            orientation: "landscape"
        )

        let size = panel.fittedPreviewSize(maxWidth: 320, maxHeight: 180)

        XCTAssertEqual(size.width, 240, accuracy: 0.001)
        XCTAssertEqual(size.height, 180, accuracy: 0.001)
        XCTAssertEqual(size.width / size.height, 4.0 / 3.0, accuracy: 0.001)
    }

    func testWidePanelFitsByWidth() {
        let panel = PanelProfile(
            width: 1_600,
            height: 400,
            gamut: "mono",
            orientation: "landscape"
        )

        let size = panel.fittedPreviewSize(maxWidth: 320, maxHeight: 180)

        XCTAssertEqual(size.width, 320, accuracy: 0.001)
        XCTAssertEqual(size.height, 80, accuracy: 0.001)
    }

    func testEmptyCanvasReturnsZeroSize() {
        let panel = PanelProfile(
            width: 1_200,
            height: 1_600,
            gamut: "spectra6",
            orientation: "portrait"
        )

        XCTAssertEqual(
            panel.fittedPreviewSize(maxWidth: 0, maxHeight: 180),
            .zero
        )
    }

    func testFitUsesServerEquivalentWhiteLetterboxGeometry() {
        let rect = ImageFitMode.fit.previewRect(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            canvasWidth: 300,
            canvasHeight: 400
        )

        XCTAssertEqual(rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(rect.y, 87.5, accuracy: 0.001)
        XCTAssertEqual(rect.width, 300, accuracy: 0.001)
        XCTAssertEqual(rect.height, 225, accuracy: 0.001)
    }

    func testFillUsesServerEquivalentCenteredCropGeometry() {
        let rect = ImageFitMode.fill.previewRect(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            canvasWidth: 300,
            canvasHeight: 400
        )

        XCTAssertEqual(rect.x, -116.667, accuracy: 0.001)
        XCTAssertEqual(rect.y, 0, accuracy: 0.001)
        XCTAssertEqual(rect.width, 533.333, accuracy: 0.001)
        XCTAssertEqual(rect.height, 400, accuracy: 0.001)
    }

    func testBlurUsesFitGeometryForItsForeground() {
        let rect = ImageFitMode.blur.previewRect(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            canvasWidth: 300,
            canvasHeight: 400
        )

        XCTAssertEqual(
            rect,
            ImageFitMode.fit.previewRect(
                sourceWidth: 1_600,
                sourceHeight: 1_200,
                canvasWidth: 300,
                canvasHeight: 400
            )
        )
    }

    func testStretchUsesTheWholePanelCanvas() {
        let rect = ImageFitMode.stretch.previewRect(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            canvasWidth: 300,
            canvasHeight: 400
        )

        XCTAssertEqual(
            rect,
            PanelImagePreviewRect(x: 0, y: 0, width: 300, height: 400)
        )
    }

    func testCenterPreservesPreparedPixelsInPanelPixelSpace() {
        let rect = ImageFitMode.center.previewRect(
            sourceWidth: 600,
            sourceHeight: 800,
            canvasWidth: 300,
            canvasHeight: 400,
            targetPixelWidth: 1_200,
            targetPixelHeight: 1_600
        )

        XCTAssertEqual(rect.x, 75, accuracy: 0.001)
        XCTAssertEqual(rect.y, 100, accuracy: 0.001)
        XCTAssertEqual(rect.width, 150, accuracy: 0.001)
        XCTAssertEqual(rect.height, 200, accuracy: 0.001)
    }

    func testPreviewGeometryRejectsInvalidSourceDimensions() {
        XCTAssertEqual(
            ImageFitMode.fit.previewRect(
                sourceWidth: 0,
                sourceHeight: 1_200,
                canvasWidth: 300,
                canvasHeight: 400
            ),
            .zero
        )
    }

    func testFramingResolvesWideSourceForPortraitTarget() {
        let crop = ImageFraming(
            focusX: 0.62,
            focusY: 0.38,
            zoom: 1.35
        ).resolvedCrop(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            targetWidth: 1_200,
            targetHeight: 1_600
        )

        XCTAssertEqual(crop.x, 0.411667, accuracy: 0.000_001)
        XCTAssertEqual(crop.y, 0.00963, accuracy: 0.000_001)
        XCTAssertEqual(crop.width, 0.416667, accuracy: 0.000_001)
        XCTAssertEqual(crop.height, 0.740741, accuracy: 0.000_001)
    }

    func testFramingResolvesIndependentlyForMixedTargetAspects() {
        let framing = ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 1)
        let portrait = framing.resolvedCrop(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            targetWidth: 1_200,
            targetHeight: 1_600
        )
        let landscape = framing.resolvedCrop(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            targetWidth: 1_600,
            targetHeight: 1_200
        )

        XCTAssertEqual(portrait.width, 0.5625, accuracy: 0.000_001)
        XCTAssertEqual(portrait.height, 1, accuracy: 0.000_001)
        XCTAssertEqual(landscape, .full)
    }

    func testFramingClampsFocusAtSourceEdges() {
        let crop = ImageFraming(focusX: 1.2, focusY: -0.2, zoom: 2)
            .resolvedCrop(
                sourceWidth: 1_600,
                sourceHeight: 1_200,
                targetWidth: 1_200,
                targetHeight: 1_600
            )

        XCTAssertEqual(crop.x + crop.width, 1, accuracy: 0.000_001)
        XCTAssertEqual(crop.y, 0, accuracy: 0.000_001)
    }
}
