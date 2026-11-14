import CryptoKit
import ImageIO
import Photos
import Testing
import UIKit
import UniformTypeIdentifiers
import TesseraeKit
@testable import Tesserae_Companion

@MainActor struct CloudPhotoPreparationTests {
    private func marker() -> UIImage {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            UIColor.blue.setFill(); context.fill(CGRect(x: 40, y: 0, width: 40, height: 40))
            UIColor.black.setStroke(); context.cgContext.setLineWidth(2)
            context.cgContext.stroke(CGRect(x: 1, y: 1, width: 78, height: 38))
        }
    }
    private func rgb(_ data: Data, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(UIImage(data: data)?.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return Array(pixels[offset..<offset + 3])
    }
    @Test func frozenFramingChangesActualOutputPixels() throws {
        let geometry = try CloudCompositionGeometry(width: 40, height: 40)
        let left = try CloudPhotoPreparer.raster(image: marker(), geometry: geometry, fit: .fill,
            framing: .init(focusX: 0, focusY: 0.5, zoom: 1))
        let right = try CloudPhotoPreparer.raster(image: marker(), geometry: geometry, fit: .fill,
            framing: .init(focusX: 1, focusY: 0.5, zoom: 1))
        #expect(try rgb(left.data, x: 20, y: 20) == [255, 0, 0])
        #expect(try rgb(right.data, x: 20, y: 20) == [0, 0, 255])
        #expect(UIImage(data: left.data)?.imageOrientation == .up)
    }
    @Test(arguments: [ImageFitMode.fit, .fill, .stretch, .center, .blur])
    func everyFitProducesExactSupportedRaster(fit: ImageFitMode) throws {
        let output = try CloudPhotoPreparer.raster(image: marker(), geometry: .init(width: 96, height: 160),
            fit: fit, framing: .centeredFill)
        let image = try #require(UIImage(data: output.data)?.cgImage)
        #expect(image.width == 96); #expect(image.height == 160)
        #expect(output.format == .png); #expect(output.data.count <= 12_582_912)
    }
    @Test func blurHasRealBackgroundAndCenterPreservesOneToOnePixels() throws {
        let geometry = try CloudCompositionGeometry(width: 160, height: 96)
        let blur = try CloudPhotoPreparer.raster(image: marker(), geometry: geometry, fit: .blur, framing: .centeredFill)
        let center = try CloudPhotoPreparer.raster(image: marker(), geometry: geometry, fit: .center, framing: .centeredFill)
        #expect(try rgb(center.data, x: 5, y: 5) == [255, 255, 255])
        #expect(try rgb(blur.data, x: 10, y: 10) != [255, 255, 255])
        #expect(try rgb(center.data, x: 50, y: 45) == [255, 0, 0])
    }
    @Test func exportContractMarkerRasters() throws {
        let directory = URL.documentsDirectory.appending(path: "CloudPhotoEvidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 200), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
            UIColor.black.setStroke(); context.cgContext.setLineWidth(5)
            context.cgContext.stroke(CGRect(x: 3, y: 3, width: 294, height: 194))
            context.cgContext.strokeEllipse(in: CGRect(x: 115, y: 65, width: 70, height: 70))
            for (label, x, y) in [("TL", 10, 10), ("TR", 248, 10), ("BL", 10, 152), ("BR", 248, 152)] {
                (label as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24), .foregroundColor: UIColor.black])
            }
        }
        try image.pngData()!.write(to: directory.appending(path: "source.png"))
        for (name, width, height) in [("land", 160, 96), ("portrait", 96, 160), ("large", 320, 192)] {
            for fit in [ImageFitMode.fit, .fill, .stretch, .center, .blur] {
                let output = try CloudPhotoPreparer.raster(image: image, geometry: .init(width: width, height: height),
                    fit: fit, framing: .init(focusX: 0.37, focusY: 0.61, zoom: 1.3))
                try output.data.write(to: directory.appending(path: "\(name)-\(fit.rawValue).png"))
            }
        }
    }

    @Test func genuineHEICBecomesPNGWithCorrectDimensions() throws {
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(marker().cgImage), nil)
        try #require(CGImageDestinationFinalize(destination))
        let source = try #require(CGImageSourceCreateWithData(bytes, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.heic.identifier)
        let prepared = try UploadImagePreparer.prepare(data: bytes as Data, fallbackContentType: "image/heic")
        let image = try #require(UIImage(data: prepared.data))
        let output = try CloudPhotoPreparer.raster(image: image, geometry: .init(width: 160, height: 96),
            fit: .fit, framing: .centeredFill)
        #expect(output.format == .png)
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(output.data as CFData, nil))) as String? == UTType.png.identifier)
    }
    @Test func cloudShareInvalidGeometryCannotBecomeDefaultPreferredOrSelectedSubset() throws {
        func device(_ id: String, _ width: Int, _ height: Int) throws -> CloudDevice {
            try JSONDecoder().decode(CloudDevice.self, from: Data("""
            {"id":"\(id)","name":"\(id)","kind":"opendisplay","panel":{"w":\(width),"h":\(height)},
             "format":"png","dither":"none","sleep_interval_s":60}
            """.utf8))
        }
        let invalid = try device("invalid", 8_000, 8_000), valid = try device("valid", 160, 96)
        let invalidOnly = CloudShareSelection(devices: [invalid], preferredIDs: ["invalid"])
        #expect(invalidOnly.initialIDs.isEmpty)
        #expect(!invalidOnly.canSend(["invalid"]))
        let replaced = CloudShareSelection(devices: [invalid, valid], preferredIDs: ["missing", "invalid"])
        #expect(replaced.initialIDs.isEmpty)
        #expect(!replaced.canSend(replaced.initialIDs))
        #expect(replaced.omittedPreferences)
        let mixed = CloudShareSelection(devices: [invalid, valid], preferredIDs: ["valid", "invalid"])
        #expect(mixed.initialIDs == ["valid"])
        #expect(mixed.omittedPreferences)
        #expect(!mixed.canSend(["valid", "invalid"]))
        #expect(!mixed.canSend(["valid", "missing"]))
        #expect(mixed.canSend(["valid"]))
        #expect(CloudShareSelection(devices: [invalid, valid], preferredIDs: []).initialIDs == ["valid"])
        let target = ShareDisplayTarget(id: "cloud:invalid", name: "Invalid", display: nil, record: nil,
            nearby: nil, cloudDeviceID: "invalid", cloudGeometryIsSupported: false)
        #expect(!target.isAvailable)
        #expect(target.unavailableReason != nil)
    }

    @Test func systemCanvasBudgetDoesNotMakeValidPackageGeometryUnselectable() throws {
        let large = try JSONDecoder().decode(CloudDevice.self, from: Data("""
        {"id":"large","name":"Large","kind":"opendisplay","panel":{"w":4000,"h":4000},
         "format":"png","dither":"none","sleep_interval_s":60}
        """.utf8))
        let selection = CloudShareSelection(devices: [large], preferredIDs: [])
        #expect(selection.initialIDs == ["large"])
        #expect(selection.canSend(["large"]))
        let target = CloudSubmissionTarget(id: large.id, name: large.name, geometry: try #require(large.panel.compositionGeometry))
        #expect(throws: CloudSystemMediaError.self) {
            try CloudSystemRasterBudget.decodeLimit(data: #require(marker().pngData()), targets: [target], fit: .fill, framings: [:])
        }
    }

    @Test func shareIntakeRejectsMultipleMediaWithoutTruncatingOneLiveProvider() throws {
        let live = NSItemProvider(object: marker())
        live.registerDataRepresentation(forTypeIdentifier: UTType.movie.identifier, visibility: .all) { completion in
            completion(Data(), nil); return nil
        }
        try validateSingleShareMedia([live])
        let another = NSItemProvider(object: marker())
        #expect(throws: (any Error).self) { try validateSingleShareMedia([live, another]) }
    }

    @Test func systemRasterPreservesSupportedFramingAndGeometry() async throws {
        let bytes = try #require(marker().pngData())
        let device = try JSONDecoder().decode(CloudDevice.self, from: Data("""
        {"id":"test","name":"Test","kind":"opendisplay","panel":{"w":80,"h":40},
         "format":"png","dither":"none","sleep_interval_s":60}
        """.utf8))
        let framing = ImageFraming(focusX: 0.75, focusY: 0.5, zoom: 2)
        let aspect = PanelAspectRatio(width: 80, height: 40)
        let app = try await CloudPhotoPreparer.prepare(data: bytes, devices: [device], selectedIDs: ["test"],
            fit: .fill, framings: [aspect: framing])
        let system = try await CloudPhotoPreparer.prepare(data: bytes, devices: [device], selectedIDs: ["test"],
            fit: .fill, framings: [aspect: framing], systemEntry: true)
        #expect(app.outputs[0].data == system.outputs[0].data)
        #expect(system.outputs[0].geometry == device.panel.compositionGeometry)
    }

    @Test func systemRasterRejectsUnsupportedCanvasFromMetadataBeforeDecode() throws {
        let target = CloudSubmissionTarget(id: "huge", name: "Huge", geometry: try .init(width: 4_000, height: 4_000))
        #expect(throws: CloudSystemMediaError.self) {
            try CloudSystemRasterBudget.decodeLimit(data: #require(marker().pngData()), targets: [target], fit: .fill, framings: [:])
        }
    }

    @Test func systemMemoryEstimateIncludesSourceAndAccumulatedOutputs() throws {
        let geometry = try CloudCompositionGeometry(width: 1_600, height: 1_200)
        try CloudSystemRasterBudget.checkWorkingSet(sourceBytes: 1_024, sourcePixels: 2_000_000,
            geometry: geometry, fit: .fill, accumulatedOutputBytes: 0)
        #expect(throws: CloudSystemMediaError.self) {
            try CloudSystemRasterBudget.checkWorkingSet(sourceBytes: CloudSystemRasterBudget.maximumWorkingBytes,
                sourcePixels: 2_000_000, geometry: geometry, fit: .fill, accumulatedOutputBytes: 0)
        }
        #expect(throws: CloudSystemMediaError.self) {
            try CloudSystemRasterBudget.checkWorkingSet(sourceBytes: 1_024, sourcePixels: 2_000_000,
                geometry: geometry, fit: .blur, accumulatedOutputBytes: 40 * 1_024 * 1_024)
        }
    }

    @Test func exportCommittedMediaForCloudAcceptance() async throws {
        let directory = URL.documentsDirectory.appending(path: "CloudMediaEvidence")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var records: [[String: Any]] = []
        func export(_ name: String, source: Data, committed: PreparedUploadImage,
                    selectedSeconds: Double? = nil) throws {
            let image = try #require(UIImage(data: committed.data))
            let output = try CloudPhotoPreparer.raster(image: image, geometry: .init(width: 160, height: 96),
                fit: .fill, framing: .centeredFill)
            let digest: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
            try source.write(to: directory.appending(path: "\(name)-source"))
            try committed.data.write(to: directory.appending(path: "\(name)-selected"))
            try output.data.write(to: directory.appending(path: "\(name)-raster.png"))
            let decoded = try #require(CGImageSourceCreateWithData(output.data as CFData, nil))
            #expect(CGImageSourceGetType(decoded) as String? == UTType.png.identifier)
            records.append(["kind": name, "sourceSHA256": digest(source), "committedSHA256": digest(committed.data), "committedContentType": committed.contentType,
                "rasterSHA256": digest(output.data), "selectedSeconds": selectedSeconds.map { $0 as Any } ?? NSNull(),
                "pixelWidth": committed.pixelWidth, "pixelHeight": committed.pixelHeight, "format": "image/png"])
        }
        let heic = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(heic, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(marker().cgImage), nil)
        try #require(CGImageDestinationFinalize(destination))
        #expect(CGImageSourceGetType(try #require(CGImageSourceCreateWithData(heic, nil))) as String? == UTType.heic.identifier)
        try export("heic", source: heic as Data,
            committed: UploadImagePreparer.prepare(data: heic as Data, fallbackContentType: "image/heic"))

        let identifier = UUID().uuidString
        let movie = try await MediaFrameFixtureWriter().makeMovie(contentIdentifier: identifier)
        let key = try await VideoFrameReader(file: movie, maximumPixelSize: 320).image(at: 1.5)
        let still = try MediaTemporaryFile(fileExtension: "jpg")
        let imageSource = try #require(CGImageSourceCreateWithData(key.data as CFData, nil))
        let stillDestination = try #require(CGImageDestinationCreateWithURL(still.url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(stillDestination, imageSource, 0,
            [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        try #require(CGImageDestinationFinalize(stillDestination))
        let exported = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MediaTemporaryFile, Error>) in
            PHLivePhoto.request(withResourceFileURLs: [still.url, movie.url], placeholderImage: nil,
                targetSize: .zero, contentMode: .aspectFit) { photo, info in
                guard (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true else { return }
                if let photo { MediaPickerSelection.exportMovie(from: photo) { continuation.resume(with: $0) } }
                else { continuation.resume(throwing: (info[PHLivePhotoInfoErrorKey] as? Error) ?? MediaFrameError.unavailable) }
            }
        }
        #expect(try Data(contentsOf: exported.url) == Data(contentsOf: movie.url))
        try Data(contentsOf: still.url).write(to: directory.appending(path: "livephoto-paired-key.jpg"))
        try Data(contentsOf: exported.url).write(to: directory.appending(path: "livephoto-paired.mov"))
        for kind in [MediaFrameSource.Kind.livePhoto, .video] {
            let reader = VideoFrameReader(file: exported, maximumPixelSize: 320)
            let primary = kind == .livePhoto ? key : try await reader.image(at: 0)
            let source = MediaFrameSource(kind: kind, primaryImage: primary, maximumPixelSize: 320) { exported }
            let session = MediaFrameSession(); session.adopt(source)
            let deadline = ContinuousClock.now + .seconds(10)
            while (session.duration == 0 || session.isBusy), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try #require(session.duration > 0)
            session.select(position: 0.8, immediately: true)
            while session.isBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            let committed = try #require(session.output)
            let expected = try await reader.image(at: 0.8 * session.duration)
            #expect(committed.data == expected.data)
            #expect(committed.data != primary.data)
            #expect(!session.usesPrimaryImage)
            try export(kind == .livePhoto ? "livephoto" : "video", source: Data(contentsOf: exported.url),
                committed: committed, selectedSeconds: 0.8 * session.duration)
            session.cancelWork()
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appending(path: "manifest.json"))
    }

}
