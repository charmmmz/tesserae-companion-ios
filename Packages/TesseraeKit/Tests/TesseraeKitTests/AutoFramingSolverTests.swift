import XCTest

@testable import TesseraeKit

final class AutoFramingSolverTests: XCTestCase {
    private let portrait = PanelAspectRatio(width: 3, height: 4)

    func testEdgeFaceIsPreservedWhenZooming() throws {
        let face = region(0.82, 0.15, 0.12, 0.18)
        let framing = try suggestion(faces: [face])
        let crop = framing.resolvedCrop(
            sourceWidth: 4, sourceHeight: 3, targetWidth: 3, targetHeight: 4)
        XCTAssertEqual(framing.zoom, 2)
        XCTAssertEqual(crop.width, 0.28125)
        XCTAssertLessThanOrEqual(crop.x, face.bounds.x)
        XCTAssertGreaterThanOrEqual(crop.x + crop.width, 0.94)
    }

    func testBothFacesFitAndSubjectCannotPullCropAwayFromThem() throws {
        let framing = try suggestion(
            faces: [region(0.60, 0.2, 0.10, 0.1), region(0.83, 0.2, 0.1, 0.1)],
            subjects: [region(0, 0, 0.5, 1)]
        )
        let crop = framing.resolvedCrop(
            sourceWidth: 4, sourceHeight: 3, targetWidth: 3, targetHeight: 4)
        XCTAssertLessThanOrEqual(crop.x, 0.60)
        XCTAssertGreaterThanOrEqual(crop.x + crop.width, 0.93)
    }

    func testWideGroupReturnsNoSafeSuggestion() {
        XCTAssertEqual(
            solve(faces: [region(0.02, 0.2, 0.1, 0.1), region(0.88, 0.2, 0.1, 0.1)]),
            .cannotPreserveSubjects)
    }

    func testPaddingMayBeReducedWithoutCuttingFaces() throws {
        _ = try suggestion(faces: [region(0.01, 0.2, 0.56, 0.1)])
    }

    func testEmptyAndLowConfidenceResultsPreserveManualFraming() {
        XCTAssertEqual(solve(), .noReliableSubject)
        XCTAssertEqual(
            solve(faces: [region(0.85, 0.2, 0.1, 0.1, confidence: 0.2)]), .noReliableSubject)
    }

    func testSubjectAloneAndDuplicateOrReorderedDetectionsAreStable() {
        let face = region(0.50, 0.3, 0.1, 0.1)
        let a = region(0.6, 0.1, 0.3, 0.8)
        let b = region(0.45, 0.2, 0.2, 0.6)
        XCTAssertEqual(
            solve(faces: [face], subjects: [a, b]),
            solve(faces: [face], subjects: [b, a, a]))
        guard case .suggested = solve(subjects: [a]) else {
            return XCTFail("Expected subject crop")
        }
    }

    func testFullImageSubjectKeepsCenteredCropWithoutRefusing() {
        XCTAssertEqual(solve(subjects: [region(0, 0, 1, 1)]), .unchanged)
    }

    func testOversizedSubjectMovesCropToRetainMoreOfIt() throws {
        // The 65%-wide subject cannot fit the portrait crop's 56.25% width.
        let framing = try suggestion(subjects: [region(0.35, 0.1, 0.65, 0.8)])
        let crop = framing.resolvedCrop(
            sourceWidth: 4, sourceHeight: 3, targetWidth: 3, targetHeight: 4)
        XCTAssertEqual(framing.zoom, 1)
        XCTAssertEqual(crop.width, 0.5625)
        // Every visible horizontal pixel now belongs to the subject. Of those placements,
        // the closest to the original center starts at the subject's left edge.
        XCTAssertEqual(crop.x, 0.35, accuracy: 0.000_001)
    }

    func testScatteredSubjectsPreferMoreVisibleAreaWithoutRefusing() throws {
        let framing = try suggestion(subjects: [
            region(0, 0.2, 0.1, 0.1), region(0.65, 0.2, 0.35, 0.6),
        ])
        let crop = framing.resolvedCrop(
            sourceWidth: 4, sourceHeight: 3, targetWidth: 3, targetHeight: 4)
        XCTAssertEqual(crop.x + crop.width, 1, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(crop.x, 0.65)
    }

    func testPartialSubjectScoringIgnoresDuplicatesAndOrderWithoutFaces() {
        let a = region(0.1, 0, 0.55, 1)
        let b = region(0.6, 0.2, 0.4, 0.4)
        XCTAssertEqual(solve(subjects: [a, b]), solve(subjects: [b, a, a]))
    }

    func testTallSubjectAlsoAllowsPartialCropForLandscapeDisplay() throws {
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 3, sourceHeight: 4, faces: [],
            subjects: [region(0.1, 0.35, 0.8, 0.65)])
        let result = AutoFramingSolver.suggest(
            analysis: analysis, target: .init(width: 4, height: 3),
            current: .centeredFill, maximumZoom: 1)
        guard case .suggested(let framing) = result else {
            return XCTFail("Expected a partial subject crop, got \(result)")
        }
        let crop = framing.resolvedCrop(
            sourceWidth: 3, sourceHeight: 4, targetWidth: 4, targetHeight: 3)
        XCTAssertEqual(crop.height, 0.5625)
        XCTAssertEqual(crop.y, 0.35, accuracy: 0.000_001)
    }

    func testMatchingAspectRatioNeedsNoChangeWhenServerDisallowsZoom() {
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 3, sourceHeight: 4, faces: [],
            subjects: [region(0.8, 0.1, 0.1, 0.1)])
        XCTAssertEqual(
            AutoFramingSolver.suggest(
                analysis: analysis, target: portrait,
                current: .centeredFill, maximumZoom: 1), .unchanged)
    }

    func testSmallSubjectZoomsAndReapplyingIsStable() throws {
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 4, sourceHeight: 3, faces: [],
            subjects: [region(0.65, 0.3, 0.1, 0.12)])
        let result = AutoFramingSolver.suggest(
            analysis: analysis, target: portrait, current: .centeredFill, maximumZoom: 4)
        guard case .suggested(let framing) = result else { return XCTFail("Expected zoom") }
        XCTAssertEqual(framing.zoom, 2)
        XCTAssertEqual(framing.focusX, 0.7, accuracy: 0.000_001)
        XCTAssertEqual(framing.focusY, 0.36, accuracy: 0.000_001)
        XCTAssertEqual(
            AutoFramingSolver.suggest(
                analysis: analysis, target: portrait, current: framing, maximumZoom: 4), .unchanged)
    }

    func testZoomObeysServerCap() {
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 4, sourceHeight: 3, faces: [], subjects: [region(0.6, 0.3, 0.1, 0.1)])
        let result = AutoFramingSolver.suggest(
            analysis: analysis, target: portrait, current: .centeredFill, maximumZoom: 1.3)
        guard case .suggested(let framing) = result else { return XCTFail("Expected zoom") }
        XCTAssertEqual(framing.zoom, 1.3)
    }

    func testGroupLimitsZoomAndPreservesFacePadding() throws {
        let framing = try suggestion(faces: [
            region(0.25, 0.2, 0.1, 0.1), region(0.5, 0.2, 0.1, 0.1),
        ])
        let crop = framing.resolvedCrop(
            sourceWidth: 4, sourceHeight: 3, targetWidth: 3, targetHeight: 4)
        XCTAssertGreaterThan(framing.zoom, 1)
        XCTAssertLessThan(framing.zoom, 2)
        XCTAssertLessThanOrEqual(crop.x, 0.235)
        XCTAssertGreaterThanOrEqual(crop.x + crop.width, 0.615)
        XCTAssertLessThanOrEqual(crop.y, 0.185)
        XCTAssertGreaterThanOrEqual(crop.y + crop.height, 0.315)
    }

    func testBodyBoundsPreventZoomingOnlyToTheFace() throws {
        let framing = try suggestion(
            faces: [region(0.5, 0.15, 0.08, 0.08)], subjects: [region(0.4, 0.1, 0.3, 0.8)])
        XCTAssertGreaterThan(framing.zoom, 1)
        XCTAssertLessThanOrEqual(framing.zoom, 1.1)
    }

    func testInvalidAutomaticZoomPolicyIsRejected() {
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 4, sourceHeight: 3, faces: [], subjects: [region(0.6, 0.3, 0.1, 0.1)])
        for occupancy in [0, -1, 1.1, .nan, .infinity] {
            var policy = AutoFramingPolicy()
            policy.targetSubjectOccupancy = occupancy
            XCTAssertEqual(
                AutoFramingSolver.suggest(
                    analysis: analysis, target: portrait, current: .centeredFill,
                    maximumZoom: 4, policy: policy), .invalidInput)
        }
    }

    func testInvalidDimensionsAndLimitsAreRejected() {
        for width in [0, -1, .nan, .infinity] {
            let analysis = PhotoSubjectAnalysis(
                sourceWidth: width, sourceHeight: 3, faces: [], subjects: [])
            XCTAssertEqual(
                AutoFramingSolver.suggest(
                    analysis: analysis, target: portrait,
                    current: .centeredFill, maximumZoom: 4), .invalidInput)
        }
        let analysis = PhotoSubjectAnalysis(
            sourceWidth: 4, sourceHeight: 3, faces: [], subjects: [])
        XCTAssertEqual(
            AutoFramingSolver.suggest(
                analysis: analysis, target: portrait,
                current: .centeredFill, maximumZoom: 0.5), .invalidInput)
        XCTAssertEqual(solve(subjects: [region(.nan, 0, 1, 1)]), .noReliableSubject)
    }

    func testLowerLeftConversionAndClamping() throws {
        let mapped = try XCTUnwrap(
            PhotoSubjectRegion.fromLowerLeft(x: 0.7, y: 0.6, width: 0.2, height: 0.3))
        XCTAssertEqual(mapped.bounds.y, 0.1, accuracy: 0.000_001)
        let clipped = try XCTUnwrap(
            PhotoSubjectRegion.fromLowerLeft(x: -0.1, y: 0.9, width: 0.2, height: 0.2))
        XCTAssertEqual(clipped.bounds.x, 0)
        XCTAssertEqual(clipped.bounds.y, 0)
        XCTAssertEqual(clipped.bounds.width, 0.1, accuracy: 0.000_001)
        XCTAssertNil(PhotoSubjectRegion.fromLowerLeft(x: 2, y: 0, width: 0.1, height: 0.1))
        XCTAssertNil(PhotoSubjectRegion.fromLowerLeft(x: 0, y: .nan, width: 0.1, height: 0.1))
    }

    private func solve(faces: [PhotoSubjectRegion] = [], subjects: [PhotoSubjectRegion] = [])
        -> AutoFramingResult
    {
        AutoFramingSolver.suggest(
            analysis: PhotoSubjectAnalysis(
                sourceWidth: 4, sourceHeight: 3, faces: faces, subjects: subjects),
            target: portrait, current: .centeredFill, maximumZoom: 4
        )
    }

    private func suggestion(faces: [PhotoSubjectRegion] = [], subjects: [PhotoSubjectRegion] = [])
        throws -> ImageFraming
    {
        let result = solve(faces: faces, subjects: subjects)
        guard case .suggested(let framing) = result else {
            XCTFail("Expected suggestion, got \(result)")
            throw NSError(domain: "AutoFramingSolverTests", code: 1)
        }
        return framing
    }

    private func region(
        _ x: Double, _ y: Double, _ width: Double, _ height: Double,
        confidence: Double = 1
    ) -> PhotoSubjectRegion {
        PhotoSubjectRegion(
            bounds: .init(x: x, y: y, width: width, height: height), confidence: confidence)
    }
}
