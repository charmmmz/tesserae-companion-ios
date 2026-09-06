import ImageIO
import TesseraeKit
import UIKit
import UniformTypeIdentifiers
import Vision
import XCTest

@testable import Tesserae_Companion

@MainActor
final class PhotoSubjectAnalyzerTests: XCTestCase {
    func testThumbnailNormalizesAllEXIFOrientationsWithoutEnlarging() throws {
        for orientation in 1...8 {
            let data = try imageData(width: 80, height: 40, orientation: orientation)
            let (image, width, height) = try VisionPhotoSubjectAnalyzer.thumbnail(data)
            let swaps = (5...8).contains(orientation)
            XCTAssertEqual(width, swaps ? 40 : 80)
            XCTAssertEqual(height, swaps ? 80 : 40)
            XCTAssertEqual(image.width, Int(width))
            XCTAssertEqual(image.height, Int(height))
        }
    }

    func testThumbnailBoundsAnalysisMemoryButPreservesSourceDimensions() throws {
        let data = try imageData(width: 2400, height: 1200)
        let (image, width, height) = try VisionPhotoSubjectAnalyzer.thumbnail(data)
        XCTAssertEqual(width, 2400)
        XCTAssertEqual(height, 1200)
        XCTAssertEqual(image.width, 1536)
        XCTAssertEqual(image.height, 768)
        XCTAssertThrowsError(try VisionPhotoSubjectAnalyzer.thumbnail(Data([0])))
    }

    func testVisionRequestsExecuteOnLocalImage() async throws {
        let data = try imageData(width: 400, height: 300)
        let analysis: PhotoSubjectAnalysis
        do {
            analysis = try await VisionPhotoSubjectAnalyzer().analyze(data)
        } catch {
            #if targetEnvironment(simulator)
                let failure = error as NSError
                var missingContext =
                    failure.domain == "com.apple.Vision" && failure.code == 9
                    && failure.localizedDescription.contains("Could not create inference context")
                if let visionError = error as? VisionError,
                    case .internalError(let detail) = visionError
                {
                    missingContext =
                        detail.contains("com.apple.Vision Code=9")
                        && detail.contains("Could not create inference context")
                }
                if missingContext {
                    throw XCTSkip(
                        "This Simulator cannot create the Vision inference context; run on a physical iPhone."
                    )
                }
            #endif
            throw error
        }
        XCTAssertEqual(analysis.sourceWidth, 400)
        XCTAssertEqual(analysis.sourceHeight, 300)
        // Model output may change between OS versions; only the normalized contract is asserted.
        for region in analysis.faces + analysis.subjects {
            XCTAssertGreaterThanOrEqual(region.bounds.x, 0)
            XCTAssertGreaterThanOrEqual(region.bounds.y, 0)
            XCTAssertLessThanOrEqual(region.bounds.x + region.bounds.width, 1.000_001)
            XCTAssertLessThanOrEqual(region.bounds.y + region.bounds.height, 1.000_001)
        }
    }

    private func imageData(width: Int, height: Int, orientation: Int = 1) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: width / 2, y: height / 4, width: width / 4, height: height / 2))
        }
        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try XCTUnwrap(image.cgImage),
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
