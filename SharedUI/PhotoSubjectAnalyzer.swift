import Foundation
import ImageIO
import TesseraeKit
import Vision

protocol PhotoSubjectAnalyzing: Sendable {
    func analyze(_ data: Data) async throws -> PhotoSubjectAnalysis
}

/// Serializes even requests whose caller has cancelled while Vision is finishing.
actor VisionPhotoSubjectAnalyzer: PhotoSubjectAnalyzing {
    private var running: Task<PhotoSubjectAnalysis, Error>?
    private var runningID: UUID?

    func analyze(_ data: Data) async throws -> PhotoSubjectAnalysis {
        let preceding = running
        let id = UUID()
        let work = Task.detached(priority: .userInitiated) {
            if let preceding { _ = try? await preceding.value }
            try Task.checkCancellation()
            let (thumbnail, width, height) = try Self.thumbnail(data)
            let handler = ImageRequestHandler(thumbnail, orientation: .up)
            let (faces, saliency) = try await handler.perform(
                DetectFaceRectanglesRequest(), GenerateObjectnessBasedSaliencyImageRequest()
            )
            try Task.checkCancellation()
            return PhotoSubjectAnalysis(
                sourceWidth: width, sourceHeight: height,
                faces: faces.compactMap { Self.region($0.boundingBox, confidence: $0.confidence) },
                subjects: saliency.salientObjects.compactMap { Self.region($0.boundingBox) }
            )
        }
        running = work
        runningID = id
        defer {
            if runningID == id {
                running = nil
                runningID = nil
            }
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    nonisolated static func thumbnail(_ data: Data) throws -> (CGImage, Double, Double) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.intValue > 0, height.intValue > 0,
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(
                        1536, max(width.intValue, height.intValue)),
                ] as CFDictionary)
        else { throw UploadImagePreparationError.decoding }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsAxes = (5...8).contains(orientation)
        return (
            image, swapsAxes ? height.doubleValue : width.doubleValue,
            swapsAxes ? width.doubleValue : height.doubleValue
        )
    }

    private nonisolated static func region(
        _ rect: NormalizedRect, confidence: Float = 1
    ) -> PhotoSubjectRegion? {
        PhotoSubjectRegion.fromLowerLeft(
            x: Double(rect.cgRect.minX), y: Double(rect.cgRect.minY),
            width: Double(rect.width), height: Double(rect.height), confidence: Double(confidence)
        )
    }
}

#if DEBUG
    /// UI journeys test application of a known suggestion, independently of OS model revisions.
    struct FixturePhotoSubjectAnalyzer: PhotoSubjectAnalyzing {
        func analyze(_ data: Data) async throws -> PhotoSubjectAnalysis {
            try await Task.sleep(for: .milliseconds(200))
            return PhotoSubjectAnalysis(
                sourceWidth: 4, sourceHeight: 3,
                faces: [
                    PhotoSubjectRegion(bounds: .init(x: 0.84, y: 0.18, width: 0.1, height: 0.14))
                ],
                subjects: []
            )
        }
    }
#endif
