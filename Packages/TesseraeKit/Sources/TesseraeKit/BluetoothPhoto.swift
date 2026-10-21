import Foundation

/// Versioned pixel layouts. The identifier fixes palette codes and packing;
/// a device must explicitly advertise a layout before the phone uses it.
public enum BluetoothPhotoFormat: String, Codable, CaseIterable, Sendable {
    case mono1 = "mono1-msb"
    case gray2 = "gray2-msb"
    case gray4 = "gray4-msb"
    case bwry2 = "bwry2-msb"
    case spectra6 = "spectra6-msb"
    case acep7 = "acep7-msb"

    public var bitsPerPixel: Int {
        switch self {
        case .mono1: 1
        case .gray2, .bwry2: 2
        case .gray4, .spectra6, .acep7: 4
        }
    }

    public var gamut: String {
        switch self {
        case .mono1: "mono"
        case .gray2: "gray_4"
        case .gray4: "gray_16"
        case .bwry2: "bwry_4"
        case .spectra6: "spectra_6"
        case .acep7: "inky_7colour"
        }
    }

    /// Palette entries are ordered by quantization index, not wire code.
    public var palette: [(red: UInt8, green: UInt8, blue: UInt8, code: UInt8)] {
        switch self {
        case .mono1: [(0, 0, 0, 0), (255, 255, 255, 1)]
        case .gray2: Self.grayPalette(levels: 4)
        case .gray4: Self.grayPalette(levels: 16)
        case .bwry2: [(0, 0, 0, 0), (255, 255, 255, 1), (255, 255, 0, 2), (255, 0, 0, 3)]
        case .spectra6: [(0, 0, 0, 0), (255, 255, 255, 1), (255, 255, 0, 2), (255, 0, 0, 3),
                         (0, 0, 255, 5), (0, 255, 0, 6)]
        case .acep7: [(0, 0, 0, 0), (255, 255, 255, 1), (0, 255, 0, 2), (0, 0, 255, 3),
                     (255, 0, 0, 4), (255, 255, 0, 5), (255, 128, 0, 6)]
        }
    }

    private static func grayPalette(levels: Int) -> [(red: UInt8, green: UInt8, blue: UInt8, code: UInt8)] {
        var inks: [(red: UInt8, green: UInt8, blue: UInt8, code: UInt8)] = []
        for i in 0..<levels {
            let value = UInt8(i * 255 / (levels - 1))
            inks.append((value, value, value, UInt8(i)))
        }
        return inks
    }
}

public enum BluetoothPhotoError: Error, LocalizedError, Equatable, Sendable {
    case invalidCapabilities, invalidPixels

    public var errorDescription: String? {
        switch self {
        case .invalidCapabilities: "This display reported an unsupported Bluetooth photo format."
        case .invalidPixels: "The photo could not be prepared for this display."
        }
    }
}

/// Authenticated Photo v2 reply; never inferred from a hardware advertisement.
/// v2.0 deliberately accepts one top-down packed format and window=1. Unsupported
/// extensions fail closed until a corresponding encoder/transport exists.
public struct BluetoothPhotoCapabilities: Codable, Equatable, Sendable {
    public let schema: Int
    public let kind: String
    public let width: Int
    public let height: Int
    public let visibleWidth: Int
    public let visibleHeight: Int
    public let xOffset: Int
    public let format: BluetoothPhotoFormat
    public let stride: Int
    public let bytes: Int
    public let chunkBytes: Int
    public let digest: String
    public let rowOrder: String
    public let lifecycle: String

    enum CodingKeys: String, CodingKey {
        case schema, kind, width, height, format, stride, bytes, digest, lifecycle
        case visibleWidth = "visible_width", visibleHeight = "visible_height"
        case xOffset = "x_offset", chunkBytes = "chunk_bytes", rowOrder = "row_order"
    }

    public func validate() throws {
        guard schema == 2, !kind.isEmpty, kind.utf8.count <= 80,
              (1...8192).contains(width), (1...8192).contains(height),
              (1...width).contains(visibleWidth), (1...height).contains(visibleHeight),
              xOffset >= 0, xOffset <= width - visibleWidth,
              stride == (width * format.bitsPerPixel + 7) / 8,
              bytes == stride * height, bytes <= 4 * 1024 * 1024,
              (1...384).contains(chunkBytes), rowOrder == "top_down",
              lifecycle == "manual", digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw BluetoothPhotoError.invalidCapabilities }
    }

    public var panel: PanelProfile {
        PanelProfile(width: visibleWidth, height: visibleHeight, gamut: format.gamut,
                     orientation: visibleWidth > visibleHeight ? "landscape" : "portrait")
    }
}

/// Deterministic local quantization/packing. Input is top-down RGBA at visible
/// dimensions; hidden columns and stride padding are white. Runs off the UI actor.
public enum BluetoothPhotoEncoder {
    public static func encode(rgba: Data, capabilities c: BluetoothPhotoCapabilities,
                              dither: Bool = true) throws -> Data {
        try c.validate()
        guard rgba.count == c.visibleWidth * c.visibleHeight * 4 else {
            throw BluetoothPhotoError.invalidPixels
        }
        let palette = c.format.palette
        let bpp = c.format.bitsPerPixel
        let perByte = 8 / bpp
        let whiteCode = palette[1].code
        // Gray palettes place white at their final entry.
        let white = c.format == .gray2 ? UInt8(3) : c.format == .gray4 ? UInt8(15) : whiteCode
        var whiteByte: UInt8 = 0
        for pixel in 0..<perByte { whiteByte |= white << (8 - bpp * (pixel + 1)) }
        var output = [UInt8](repeating: whiteByte, count: c.bytes)
        var errors = [Double](repeating: 0, count: (c.visibleWidth + 2) * 3)
        var next = errors
        try rgba.withUnsafeBytes { (pixels: UnsafeRawBufferPointer) in
            for y in 0..<c.visibleHeight {
                try Task.checkCancellation()
                for x in 0..<c.visibleWidth {
                    let offset = (y * c.visibleWidth + x) * 4
                    let e = (x + 1) * 3
                    let r = min(255, max(0, Double(pixels[offset]) + errors[e]))
                    let g = min(255, max(0, Double(pixels[offset + 1]) + errors[e + 1]))
                    let b = min(255, max(0, Double(pixels[offset + 2]) + errors[e + 2]))
                    var best = 0, distance = Double.infinity
                    for i in palette.indices {
                        let dr = r - Double(palette[i].red)
                        let dg = g - Double(palette[i].green)
                        let db = b - Double(palette[i].blue)
                        let d = dr * dr + dg * dg + db * db
                        if d < distance { distance = d; best = i }
                    }
                    let bx = x + c.xOffset
                    let shift = 8 - bpp * (bx % perByte + 1)
                    let mask = UInt8((1 << bpp) - 1) << shift
                    let target = y * c.stride + bx / perByte
                    output[target] = (output[target] & ~mask) | (palette[best].code << shift)
                    if dither {
                        let residuals = [r - Double(palette[best].red), g - Double(palette[best].green),
                                         b - Double(palette[best].blue)]
                        for channel in 0..<3 {
                            let error = residuals[channel]
                            errors[e + 3 + channel] += error * 7 / 16
                            next[e - 3 + channel] += error * 3 / 16
                            next[e + channel] += error * 5 / 16
                            next[e + 3 + channel] += error / 16
                        }
                    }
                }
                swap(&errors, &next)
                for i in next.indices { next[i] = 0 }
            }
        }
        return Data(output)
    }
}
