import CoreGraphics
import Foundation
import ImageIO
@testable import TesseraeKit
import XCTest

final class ActivityThumbnailStoreTests: XCTestCase {
    func testStoresBoundedJPEGAndLoadsItByJob() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActivityThumbnailStore(
            directoryURL: directory,
            policy: ActivityThumbnailPolicy(maximumPixelEdge: 80)
        )

        let thumbnail = try await store.save(
            imageData: try imageData(width: 400, height: 300),
            jobID: "job_123",
            instanceID: "instance-1",
            createdAt: Date()
        )

        let stored = try await store.data(
            forJobID: "job_123",
            instanceID: "instance-1"
        )
        XCTAssertEqual(stored, thumbnail)
        guard
            let source = CGImageSourceCreateWithData(thumbnail as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else {
            return XCTFail("Stored thumbnail is not a decodable image.")
        }
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertLessThanOrEqual(
            (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
            80
        )
        XCTAssertLessThanOrEqual(
            (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0,
            80
        )
    }

    func testKeepsNewestRecordsWithinCountLimit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActivityThumbnailStore(
            directoryURL: directory,
            policy: ActivityThumbnailPolicy(
                maximumPixelEdge: 40,
                maximumCount: 2
            )
        )
        let now = Date()
        let image = try imageData(width: 100, height: 80)

        for offset in 0..<3 {
            _ = try await store.save(
                imageData: image,
                jobID: "job-\(offset)",
                instanceID: "instance",
                createdAt: now.addingTimeInterval(TimeInterval(offset))
            )
        }

        let oldest = try await store.data(
            forJobID: "job-0",
            instanceID: "instance"
        )
        let middle = try await store.data(
            forJobID: "job-1",
            instanceID: "instance"
        )
        let newest = try await store.data(
            forJobID: "job-2",
            instanceID: "instance"
        )
        XCTAssertNil(oldest)
        XCTAssertNotNil(middle)
        XCTAssertNotNil(newest)
    }

    func testPurgesExpiredRecordsAndClearsOnlyOneInstance() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileActivityThumbnailStore(
            directoryURL: directory,
            policy: ActivityThumbnailPolicy(
                maximumPixelEdge: 40,
                retentionInterval: 10
            )
        )
        let image = try imageData(width: 100, height: 80)
        let now = Date()

        _ = try await store.save(
            imageData: image,
            jobID: "old",
            instanceID: "one",
            createdAt: now.addingTimeInterval(-20)
        )
        _ = try await store.save(
            imageData: image,
            jobID: "current-one",
            instanceID: "one",
            createdAt: now
        )
        _ = try await store.save(
            imageData: image,
            jobID: "current-two",
            instanceID: "two",
            createdAt: now
        )

        try await store.purge(referenceDate: now)
        let expired = try await store.data(
            forJobID: "old",
            instanceID: "one"
        )
        XCTAssertNil(expired)

        try await store.clear(instanceID: "one")
        let cleared = try await store.data(
            forJobID: "current-one",
            instanceID: "one"
        )
        let preserved = try await store.data(
            forJobID: "current-two",
            instanceID: "two"
        )
        XCTAssertNil(cleared)
        XCTAssertNotNil(preserved)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(
                path: "TesseraeActivityThumbnailTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
    }

    private func imageData(width: Int, height: Int) throws -> Data {
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
            throw ActivityThumbnailStoreError.encoding
        }
        context.setFillColor(
            CGColor(red: 0.08, green: 0.68, blue: 0.58, alpha: 1)
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ActivityThumbnailStoreError.encoding
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            throw ActivityThumbnailStoreError.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ActivityThumbnailStoreError.encoding
        }
        return output as Data
    }
}
