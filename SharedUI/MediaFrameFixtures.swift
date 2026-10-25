#if DEBUG
import AVFoundation
import CoreVideo
import TesseraeKit
import UIKit

/// Small generated clips make frame selection testable without Photos access or user media.
@MainActor enum MediaFrameFixtures {
    static func source(kind: MediaFrameSource.Kind, rotated: Bool = false) async throws -> MediaFrameSource {
        let movie = try await MediaFrameFixtureWriter().makeMovie(rotated: rotated)
        let primary: PreparedUploadImage
        if kind == .video {
            primary = try await VideoFrameReader(file: movie, maximumPixelSize: 640).image(at: 0)
        } else {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200), format: format).image { context in
                UIColor(red: 0.92, green: 0.86, blue: 0.66, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
                UIColor(red: 0.68, green: 0.16, blue: 0.12, alpha: 1).setFill()
                context.cgContext.fillEllipse(in: CGRect(x: 110, y: 50, width: 100, height: 100))
            }
            guard let data = image.pngData() else { throw MediaFrameError.encoding }
            primary = try UploadImagePreparer.prepare(data: data, fallbackContentType: "image/png")
        }
        return MediaFrameSource(kind: kind, primaryImage: primary, maximumPixelSize: 640) { movie }
    }
}

actor MediaFrameFixtureWriter {
    func makeMovie(rotated: Bool = false, contentIdentifier: String? = nil, frameRate: Int32 = 4) async throws -> MediaTemporaryFile {
        let file = try MediaTemporaryFile(fileExtension: "mov")
        let writer = try AVAssetWriter(outputURL: file.url, fileType: .mov)
        var metadataInput: AVAssetWriterInput?
        var metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
        if let contentIdentifier {
            let identifier = AVMutableMetadataItem()
            identifier.identifier = .quickTimeMetadataContentIdentifier
            identifier.value = contentIdentifier as NSString
            writer.metadata = [identifier]
            var format: CMMetadataFormatDescription?
            let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [[
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
                    kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8,
                ]] as CFArray, formatDescriptionOut: &format)
            guard status == noErr, let format else { throw MediaFrameError.encoding }
            let input = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
            metadataInput = input
            metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: input)
            writer.add(input)
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 200,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 200,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MediaFrameError.encoding }
        writer.startSession(atSourceTime: .zero)
        if let metadataInput, let metadataAdaptor {
            while !metadataInput.isReadyForMoreMediaData {
                try Task.checkCancellation()
                guard writer.status == .writing else { throw writer.error ?? MediaFrameError.encoding }
                try await Task.sleep(for: .milliseconds(5))
            }
            let time = AVMutableMetadataItem()
            time.keySpace = .quickTimeMetadata
            time.key = "com.apple.quicktime.still-image-time" as NSString
            time.value = NSNumber(value: Int8(0))
            time.dataType = kCMMetadataBaseDataType_SInt8 as String
            guard metadataAdaptor.append(AVTimedMetadataGroup(items: [time],
                timeRange: CMTimeRange(start: CMTime(value: 6, timescale: 4), duration: CMTime(value: 1, timescale: 4))))
            else { throw writer.error ?? MediaFrameError.encoding }
        }
        for index in 0..<12 {
            try Task.checkCancellation()
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error ?? MediaFrameError.encoding }
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, 320, 200, kCVPixelFormatType_32ARGB, [
                kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ] as CFDictionary, &buffer) == kCVReturnSuccess, let buffer else { throw MediaFrameError.encoding }
            CVPixelBufferLockBaseAddress(buffer, [])
            guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 320, height: 200,
                                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
            else { CVPixelBufferUnlockBaseAddress(buffer, []); throw MediaFrameError.encoding }
            context.setFillColor(CGColor(red: 0.34, green: 0.52, blue: 0.48, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            context.setFillColor(CGColor(red: 0.92, green: 0.86, blue: 0.66, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 60))
            context.setFillColor(CGColor(red: 0.74, green: 0.18, blue: 0.12, alpha: 1))
            context.fillEllipse(in: CGRect(x: 15 + index * 18, y: 80, width: 70, height: 70))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(index), timescale: frameRate))
            else { throw writer.error ?? MediaFrameError.encoding }
        }
        input.markAsFinished()
        metadataInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MediaFrameError.encoding }
        return file
    }
}
#endif
