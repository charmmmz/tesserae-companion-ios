import Foundation
import UIKit
import TesseraeKit

/// The native PicPak frame is 400x300, B/W/Y/R, 2 bpp, bottom row first.
/// Rendering uses the same crop geometry as the interactive preview.
enum PicPakPhotoEncoder {
    static let width = 400, height = 300
    @MainActor
    static func raster(image: UIImage, fit: ImageFitMode, framing: ImageFraming) throws -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
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
        guard let cgImage = rendered.cgImage else { throw UploadImagePreparationError.decoding }
        var rgba = Data(count: width * height * 4)
        let success = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                              | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { throw UploadImagePreparationError.decoding }
        return rgba
    }

    /// Floyd–Steinberg quantization against Tesserae's nominal BWRY palette.
    nonisolated static func encode(rgba: Data) throws -> Data {
        guard rgba.count == width * height * 4 else { throw BLESetupProtocolError.invalidFrame }
        let pixels = [UInt8](rgba)
        let palette: [[Double]] = [[0,0,0], [255,255,255], [255,255,0], [255,0,0]]
        var output = [UInt8](repeating: 0, count: width * height / 4)
        var current = [Double](repeating: 0, count: (width + 2) * 3)
        var next = current
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let p = (y * width + x) * 4, e = (x + 1) * 3
                let color = (0..<3).map { min(255, max(0, Double(pixels[p + $0]) + current[e + $0])) }
                var index = 0, distance = Double.infinity
                for i in palette.indices {
                    let d = (0..<3).reduce(0.0) { $0 + pow(color[$1] - palette[i][$1], 2) }
                    if d < distance { index = i; distance = d }
                }
                output[((height - 1 - y) * width + x) / 4] |= UInt8(index) << (6 - (x % 4) * 2)
                for c in 0..<3 {
                    let error = color[c] - palette[index][c]
                    current[e + 3 + c] += error * 7 / 16
                    next[e - 3 + c] += error * 3 / 16
                    next[e + c] += error * 5 / 16
                    next[e + 3 + c] += error / 16
                }
            }
            current = next
            next = [Double](repeating: 0, count: next.count)
        }
        return Data(output)
    }
}
