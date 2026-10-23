import Foundation
import UIKit
import TesseraeKit

enum LocalBluetoothPhotoRenderer {
    /// Decode the wire pixels rather than retaining the original photo. This includes
    /// quantization, visible-column cropping, and PicPak's bottom-up row order.
    @MainActor
    static func previewPNG(frame: Data, capabilities c: BluetoothPhotoCapabilities?) throws -> Data {
        if let c { try c.validate() }
        let sourceWidth = c?.visibleWidth ?? PicPakPhotoEncoder.width
        let sourceHeight = c?.visibleHeight ?? PicPakPhotoEncoder.height
        let format = c?.format ?? .bwry2
        let stride = c?.stride ?? PicPakPhotoEncoder.width / 4
        guard frame.count == (c?.bytes ?? BLEPhotoTransfer.byteCount) else { throw BluetoothPhotoError.invalidPixels }
        let scale = min(1, 760.0 / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int(Double(sourceWidth) * scale))
        let height = max(1, Int(Double(sourceHeight) * scale))
        let bpp = format.bitsPerPixel
        let palette = Dictionary(uniqueKeysWithValues: format.palette.map { ($0.code, ($0.red, $0.green, $0.blue)) })
        var rgba = Data(count: width * height * 4)
        try rgba.withUnsafeMutableBytes { (pixels: UnsafeMutableRawBufferPointer) in
            try frame.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
                for y in 0..<height {
                    let sy = min(sourceHeight - 1, y * sourceHeight / height)
                    let row = c == nil ? sourceHeight - 1 - sy : sy
                    for x in 0..<width {
                        let sx = min(sourceWidth - 1, x * sourceWidth / width) + (c?.xOffset ?? 0)
                        let byte = bytes[row * stride + sx / (8 / bpp)]
                        let shift = 8 - bpp * (sx % (8 / bpp) + 1)
                        let code = (byte >> shift) & UInt8((1 << bpp) - 1)
                        guard let ink = palette[code] else { throw BluetoothPhotoError.invalidPixels }
                        let p = (y * width + x) * 4
                        pixels[p] = ink.0; pixels[p + 1] = ink.1; pixels[p + 2] = ink.2; pixels[p + 3] = 255
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let png = UIImage(cgImage: image).pngData() else { throw BluetoothPhotoError.invalidPixels }
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
