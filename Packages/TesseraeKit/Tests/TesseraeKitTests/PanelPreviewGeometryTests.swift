import XCTest
@testable import TesseraeKit

final class PanelPreviewGeometryTests: XCTestCase {
    func testPanelAspectRatioReducesResolutionAndKeepsOrientationDistinct() {
        XCTAssertEqual(
            PanelAspectRatio(width: 400, height: 300),
            PanelAspectRatio(width: 1_200, height: 900)
        )
        XCTAssertEqual(
            PanelAspectRatio(width: 400, height: 300).displayName,
            "4:3"
        )
        XCTAssertNotEqual(
            PanelAspectRatio(width: 400, height: 300),
            PanelAspectRatio(width: 1_200, height: 1_600)
        )
    }

    func testImageSendTargetsShareFramingOnlyWithinOneAspectRatio() throws {
        let landscape = PanelAspectRatio(width: 400, height: 300)
        let portrait = PanelAspectRatio(width: 1_200, height: 1_600)
        let groups = imageSendTargetGroups(
            displays: [
                display(id: "black", width: 400, height: 300),
                display(id: "blue", width: 1_200, height: 900),
                display(id: "living-room", width: 1_200, height: 1_600),
            ],
            selectedDeviceIDs: ["black", "blue", "living-room"],
            framingsByAspect: [
                landscape: ImageFraming(focusX: 0.4, focusY: 0.5, zoom: 1.2),
                portrait: ImageFraming(focusX: 0.5, focusY: 0.7, zoom: 1.5),
            ],
            separatesByAspect: true,
            maximumZoom: 4
        )

        XCTAssertEqual(groups.count, 2)
        let landscapeGroup = try XCTUnwrap(
            groups.first { $0.aspectRatio == landscape }
        )
        XCTAssertEqual(landscapeGroup.deviceIDs, ["black", "blue"])
        XCTAssertEqual(
            landscapeGroup.framing,
            ImageFraming(focusX: 0.4, focusY: 0.5, zoom: 1.2)
        )
        let portraitGroup = try XCTUnwrap(
            groups.first { $0.aspectRatio == portrait }
        )
        XCTAssertEqual(portraitGroup.deviceIDs, ["living-room"])
        XCTAssertEqual(
            portraitGroup.framing,
            ImageFraming(focusX: 0.5, focusY: 0.7, zoom: 1.5)
        )
    }

    func testImageSendTargetsStayInOneGroupWithoutFraming() throws {
        let groups = imageSendTargetGroups(
            displays: [
                display(id: "landscape", width: 400, height: 300),
                display(id: "portrait", width: 1_200, height: 1_600),
            ],
            selectedDeviceIDs: ["landscape", "portrait"],
            framingsByAspect: [:],
            separatesByAspect: false,
            maximumZoom: 4
        )

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.id, "all")
        XCTAssertEqual(group.deviceIDs, ["landscape", "portrait"])
        XCTAssertNil(group.framing)
    }

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

    func testFramedPreviewRectDisplaysTheResolvedSourceCrop() {
        let rect = ImageFraming.centeredFill.framedPreviewRect(
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            canvasWidth: 300,
            canvasHeight: 400,
            targetWidth: 1_200,
            targetHeight: 1_600
        )

        XCTAssertEqual(rect.x, -116.666667, accuracy: 0.000_001)
        XCTAssertEqual(rect.y, 0, accuracy: 0.000_001)
        XCTAssertEqual(rect.width, 533.333333, accuracy: 0.000_001)
        XCTAssertEqual(rect.height, 400, accuracy: 0.000_001)
    }

    func testPreviewDragMovesTheSourceOppositeTheFinger() {
        let framing = ImageFraming.centeredFill.applyingPreviewGesture(
            translationX: 53.333333,
            translationY: 0,
            magnification: 1,
            canvasWidth: 300,
            canvasHeight: 400,
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            targetWidth: 1_200,
            targetHeight: 1_600,
            maximumZoom: 4
        )

        XCTAssertEqual(framing.focusX, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(framing.focusY, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(framing.zoom, 1, accuracy: 0.000_001)
    }

    func testPreviewPinchUsesTheAdvertisedBoundAndPreservesFocus() {
        let framing = ImageFraming(
            focusX: 0.62,
            focusY: 0.38,
            zoom: 1
        ).applyingPreviewGesture(
            translationX: 0,
            translationY: 0,
            magnification: 8,
            canvasWidth: 300,
            canvasHeight: 400,
            sourceWidth: 1_600,
            sourceHeight: 1_200,
            targetWidth: 1_200,
            targetHeight: 1_600,
            maximumZoom: 4
        )

        XCTAssertEqual(framing.focusX, 0.62, accuracy: 0.000_001)
        XCTAssertEqual(framing.focusY, 0.38, accuracy: 0.000_001)
        XCTAssertEqual(framing.zoom, 4, accuracy: 0.000_001)
    }

    private func display(id: String, width: Int, height: Int) -> DisplaySummary {
        DisplaySummary(
            id: id,
            name: id,
            kind: "test",
            iconName: "display",
            panel: PanelProfile(
                width: width,
                height: height,
                gamut: "mono",
                orientation: width >= height ? "landscape" : "portrait"
            ),
            freshness: .fresh
        )
    }
}
