import CoreGraphics
import Foundation
import ImageIO
@testable import TesseraeKit
import UniformTypeIdentifiers
import XCTest

final class UploadImagePreparationTests: XCTestCase {
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
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            throw UploadImagePreparationError.decoding
        }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
    }
}
