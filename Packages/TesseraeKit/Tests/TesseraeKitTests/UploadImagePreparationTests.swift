import CoreGraphics
import Foundation
import ImageIO
@testable import TesseraeKit
import UniformTypeIdentifiers
import XCTest

final class UploadImagePreparationTests: XCTestCase {
    func testEXIFRightFixtureResolvesCropInOrientationNormalizedSpace() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(
                path: "../../../../Contracts/Fixtures/image-framing-exif-rotate-90.json"
            )
            .standardizedFileURL
        let fixture = try TesseraeJSON.decoder().decode(
            EXIFFramingFixture.self,
            from: Data(contentsOf: fixtureURL)
        )
        let input = try XCTUnwrap(Data(base64Encoded: fixture.jpegBase64))

        let source = try imageProperties(in: input)
        XCTAssertEqual(source.width, fixture.rawSource.width)
        XCTAssertEqual(source.height, fixture.rawSource.height)
        XCTAssertEqual(source.orientation, fixture.rawSource.exifOrientation)

        let prepared = try UploadImagePreparer.prepare(
            data: input,
            fallbackContentType: fixture.contentType
        )
        XCTAssertEqual(prepared.pixelWidth, fixture.normalizedSource.width)
        XCTAssertEqual(prepared.pixelHeight, fixture.normalizedSource.height)
        XCTAssertEqual(
            try imageProperties(in: prepared.data).orientation,
            fixture.normalizedSource.exifOrientation
        )

        let crop = fixture.framing.resolvedCrop(
            sourceWidth: Double(prepared.pixelWidth),
            sourceHeight: Double(prepared.pixelHeight),
            targetWidth: Double(fixture.target.width),
            targetHeight: Double(fixture.target.height)
        )
        XCTAssertEqual(crop.x, fixture.expectedCrop.x, accuracy: 0.000_001)
        XCTAssertEqual(crop.y, fixture.expectedCrop.y, accuracy: 0.000_001)
        XCTAssertEqual(
            crop.width,
            fixture.expectedCrop.width,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            crop.height,
            fixture.expectedCrop.height,
            accuracy: 0.000_001
        )

        let rawBufferCrop = fixture.framing.resolvedCrop(
            sourceWidth: Double(fixture.rawSource.width),
            sourceHeight: Double(fixture.rawSource.height),
            targetWidth: Double(fixture.target.width),
            targetHeight: Double(fixture.target.height)
        )
        XCTAssertGreaterThan(abs(rawBufferCrop.x - crop.x), 0.01)

        let clampCrop = fixture.clampCase.framing.resolvedCrop(
            sourceWidth: Double(prepared.pixelWidth),
            sourceHeight: Double(prepared.pixelHeight),
            targetWidth: Double(fixture.target.width),
            targetHeight: Double(fixture.target.height)
        )
        XCTAssertEqual(
            clampCrop.x,
            fixture.clampCase.expectedCrop.x,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            clampCrop.y,
            fixture.clampCase.expectedCrop.y,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            clampCrop.width,
            fixture.clampCase.expectedCrop.width,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            clampCrop.height,
            fixture.clampCase.expectedCrop.height,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(
            fixture.clampCase.framing.focusX - clampCrop.width / 2,
            1 - clampCrop.width
        )
        XCTAssertLessThan(
            fixture.clampCase.framing.focusY - clampCrop.height / 2,
            0
        )
        XCTAssertEqual(clampCrop.x, 1 - clampCrop.width, accuracy: 0.000_001)
        XCTAssertEqual(clampCrop.y, 0, accuracy: 0.000_001)
    }

    func testRotatesEXIFRightImageIntoUprightPixels() throws {
        let input = try jpeg(
            width: 4,
            height: 3,
            orientation: .right
        )

        let prepared = try UploadImagePreparer.prepare(
            data: input,
            fallbackContentType: "image/jpeg"
        )

        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertEqual(prepared.fileExtension, "jpg")
        XCTAssertEqual(prepared.pixelWidth, 3)
        XCTAssertEqual(prepared.pixelHeight, 4)
        XCTAssertEqual(try orientation(in: prepared.data), 1)
    }

    func testKeepsAlreadyUprightImageBytes() throws {
        let input = try jpeg(
            width: 4,
            height: 3,
            orientation: .up
        )

        let prepared = try UploadImagePreparer.prepare(
            data: input,
            fallbackContentType: "image/jpeg"
        )

        XCTAssertEqual(prepared.data, input)
        XCTAssertEqual(prepared.pixelWidth, 4)
        XCTAssertEqual(prepared.pixelHeight, 3)
    }

    func testDownsamplesToRequestedMaximumPixelSize() throws {
        let input = try jpeg(
            width: 400,
            height: 300,
            orientation: .up
        )

        let prepared = try UploadImagePreparer.prepare(
            data: input,
            fallbackContentType: "image/jpeg",
            maximumPixelSize: 100
        )

        XCTAssertEqual(prepared.pixelWidth, 100)
        XCTAssertEqual(prepared.pixelHeight, 75)
        XCTAssertEqual(try orientation(in: prepared.data), 1)
    }

    private func jpeg(
        width: Int,
        height: Int,
        orientation: CGImagePropertyOrientation
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw UploadImagePreparationError.encoding
        }
        context.setFillColor(CGColor(red: 0.1, green: 0.7, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw UploadImagePreparationError.encoding
        }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else {
            throw UploadImagePreparationError.encoding
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImagePropertyOrientation: orientation.rawValue,
                kCGImageDestinationLossyCompressionQuality: 0.9,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw UploadImagePreparationError.encoding
        }
        return output as Data
    }

    private func orientation(in data: Data) throws -> Int {
        try imageProperties(in: data).orientation
    }

    private func imageProperties(
        in data: Data
    ) throws -> (width: Int, height: Int, orientation: Int) {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            throw UploadImagePreparationError.decoding
        }
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (width, height, orientation)
    }
}

private struct EXIFFramingFixture: Decodable {
    let contentType: String
    let jpegBase64: String
    let rawSource: EXIFSourceDescription
    let normalizedSource: EXIFSourceDescription
    let target: FixturePixelSize
    let framing: ImageFraming
    let expectedCrop: FixtureNormalizedCrop
    let clampCase: EXIFFramingCase
}

private struct EXIFFramingCase: Decodable {
    let framing: ImageFraming
    let expectedCrop: FixtureNormalizedCrop
}

private struct EXIFSourceDescription: Decodable {
    let width: Int
    let height: Int
    let exifOrientation: Int
}

private struct FixturePixelSize: Decodable {
    let width: Int
    let height: Int
}

private struct FixtureNormalizedCrop: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
