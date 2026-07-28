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
}
