import Foundation
import UIKit
import TesseraeKit

enum LocalBluetoothPhotoRenderer {
    /// Thumbnail the same composed pixels that are sent, before ink quantization.
    @MainActor
    static func previewPNG(rgba: Data, width: Int, height: Int) throws -> Data {
        guard width > 0, height > 0, width <= 8192, height <= 8192,
              rgba.count == width * height * 4,
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                      .union(.byteOrder32Big),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw BluetoothPhotoError.invalidPixels }
        let scale = min(1, 760.0 / Double(max(width, height)))
        let size = CGSize(width: max(1, Int(Double(width) * scale)),
                          height: max(1, Int(Double(height) * scale)))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let thumbnail = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = thumbnail.pngData() else { throw BluetoothPhotoError.invalidPixels }
        return png
    }

    @MainActor
    static func raster(image: UIImage, fit: ImageFitMode, framing: ImageFraming,
                       capabilities c: BluetoothPhotoCapabilities) throws -> Data {
        try c.validate()
        let width = c.visibleWidth, height = c.visibleHeight
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let raster = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if fit == .fill {
                let crop = framing.resolvedCrop(sourceWidth: image.size.width, sourceHeight: image.size.height,
                    targetWidth: Double(width), targetHeight: Double(height))
                image.draw(in: CGRect(x: -crop.x * Double(width) / crop.width,
                    y: -crop.y * Double(height) / crop.height,
                    width: Double(width) / crop.width, height: Double(height) / crop.height))
            } else {
                let rect = fit.previewRect(sourceWidth: image.size.width, sourceHeight: image.size.height,
                    canvasWidth: Double(width), canvasHeight: Double(height))
                image.draw(in: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
            }
        }
        guard let cgImage = raster.cgImage else { throw UploadImagePreparationError.decoding }
        var rgba = Data(count: width * height * 4)
        let ok = rgba.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // CGContext's raw rows must agree with the top-down wire contract.
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw UploadImagePreparationError.decoding }
        return rgba
    }

    /// CPU-only immutable inputs cross the actor boundary. Explicitly propagate
    /// cancellation so closing the editor cannot leave a large encoder running.
    static func encode(rgba: Data, capabilities: BluetoothPhotoCapabilities) async throws -> Data {
        let work = Task.detached(priority: .userInitiated) {
            try BluetoothPhotoEncoder.encode(rgba: rgba, capabilities: capabilities)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}
