import ImageIO
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
}
