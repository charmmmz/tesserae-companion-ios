import Foundation
import CryptoKit
import Testing
@testable import TesseraeKit

struct BluetoothPhotoTests {
    static func capabilities(format: BluetoothPhotoFormat = .spectra6, width: Int = 6, height: Int = 1,
                             visibleWidth: Int? = nil, xOffset: Int = 0,
                             changes: [String: Any] = [:]) throws -> BluetoothPhotoCapabilities {
        var object: [String: Any] = [
            "schema": 2, "kind": "test_panel", "width": width, "height": height,
            "visible_width": visibleWidth ?? width, "visible_height": height, "x_offset": xOffset,
            "format": format.rawValue, "stride": (width * format.bitsPerPixel + 7) / 8,
            "bytes": ((width * format.bitsPerPixel + 7) / 8) * height, "chunk_bytes": 384,
            "digest": String(repeating: "a", count: 64), "row_order": "top_down", "lifecycle": "manual"
        ]
        object.merge(changes) { _, new in new }
        return try JSONDecoder().decode(BluetoothPhotoCapabilities.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: [
        ("schema", 3), ("width", 0), ("height", -1), ("visible_width", 7),
        ("x_offset", 1), ("stride", 4), ("bytes", 4), ("chunk_bytes", 0),
        ("chunk_bytes", 385), ("width", Int.max), ("max_window", 0),
        ("max_window", 5), ("max_window", Int.max)
    ])
    func rejectsInvalidGeometryAndBudgets(key: String, value: Int) throws {
        let caps = try Self.capabilities(changes: [key: value])
        #expect(throws: BluetoothPhotoError.invalidCapabilities) { try caps.validate() }
    }

    @Test(arguments: [("row_order", "bottom_up"), ("lifecycle", "forever"), ("digest", "invalid"), ("kind", "")])
    func rejectsUnsupportedContract(key: String, value: String) throws {
        let caps = try Self.capabilities(changes: [key: value])
        #expect(throws: BluetoothPhotoError.invalidCapabilities) { try caps.validate() }
    }

    @Test func rejectsBooleanDimensionsAndUnknownFormat() {
        #expect(throws: (any Error).self) { try Self.capabilities(changes: ["width": true]) }
        #expect(throws: (any Error).self) { try Self.capabilities(changes: ["format": "future-format"]) }
        #expect(throws: (any Error).self) { try Self.capabilities(changes: ["max_window": true]) }
        #expect(throws: (any Error).self) { try Self.capabilities(changes: ["max_window": 1.5]) }
        #expect(throws: (any Error).self) { try Self.capabilities(changes: ["max_window": "4"]) }
    }

    @Test func missingWindowKeepsOriginalStopAndWaitContract() throws {
        let original = try Self.capabilities()
        try original.validate()
        #expect(original.maxWindow == nil)
        let advertised = try Self.capabilities(changes: ["max_window": 4])
        try advertised.validate()
        #expect(advertised.maxWindow == 4)
        // Transport negotiation does not change the pixel/layout digest.
        #expect(advertised.digest == original.digest)
        #expect(advertised.panel == original.panel)
    }

    @Test(arguments: 1...4)
    func acceptsOnlyBoundedWindowSizes(window: Int) throws {
        let caps = try Self.capabilities(changes: ["max_window": window])
        try caps.validate()
        let encoded = try JSONEncoder().encode(caps)
        let roundTrip = try JSONDecoder().decode(BluetoothPhotoCapabilities.self, from: encoded)
        #expect(roundTrip.maxWindow == window)
    }

    @Test func spectraUsesSparseControllerCodes() throws {
        let rgba = Data([0,0,0,255, 255,255,255,255, 255,255,0,255,
                         255,0,0,255, 0,0,255,255, 0,255,0,255])
        #expect(try BluetoothPhotoEncoder.encode(rgba: rgba, capabilities: Self.capabilities(), dither: false)
                == Data([0x01, 0x23, 0x56]))
    }

    @Test func acepUsesItsOwnSevenColorOrder() throws {
        let rgba = Data([0,0,0,255, 255,255,255,255, 0,255,0,255, 0,0,255,255,
                         255,0,0,255, 255,255,0,255, 255,128,0,255, 255,255,255,255])
        let caps = try Self.capabilities(format: .acep7, width: 8)
        #expect(try BluetoothPhotoEncoder.encode(rgba: rgba, capabilities: caps, dither: false)
                == Data([0x01, 0x23, 0x45, 0x61]))
    }

    @Test func topDownRowsAreNotPicPakBottomUp() throws {
        let inks: [UInt8] = [0,0,0,255, 255,255,255,255, 255,255,0,255, 255,0,0,255]
        let rgba = Data(inks + [255,0,0,255, 255,255,0,255, 255,255,255,255, 0,0,0,255])
        let caps = try Self.capabilities(format: .bwry2, width: 4, height: 2)
        #expect(try BluetoothPhotoEncoder.encode(rgba: rgba, capabilities: caps, dither: false) == Data([0x1b, 0xe4]))
    }

    @Test func hiddenColumnsAndPartialByteStayWhite() throws {
        let caps = try Self.capabilities(format: .mono1, width: 8, visibleWidth: 2, xOffset: 3)
        #expect(try BluetoothPhotoEncoder.encode(rgba: Data([0,0,0,255, 0,0,0,255]),
            capabilities: caps, dither: false) == Data([0xe7]))
        let odd = try Self.capabilities(format: .mono1, width: 3)
        #expect(try BluetoothPhotoEncoder.encode(rgba: Data([255,255,255,255, 0,0,0,255, 255,255,255,255]),
            capabilities: odd, dither: false) == Data([0xbf]))
    }

    @Test(arguments: [(BluetoothPhotoFormat.gray2, Data([0x1b])), (.gray4, Data([0x05, 0xaf]))])
    func linearGrayLevels(format: BluetoothPhotoFormat, expected: Data) throws {
        let rgba = Data([0,0,0,255, 85,85,85,255, 170,170,170,255, 255,255,255,255])
        #expect(try BluetoothPhotoEncoder.encode(rgba: rgba,
            capabilities: Self.capabilities(format: format, width: 4), dither: false) == expected)
    }

    @Test func rejectsWrongPixelCountBeforeEncoding() throws {
        #expect(throws: BluetoothPhotoError.invalidPixels) {
            try BluetoothPhotoEncoder.encode(rgba: Data(), capabilities: Self.capabilities())
        }
    }

    @Test(arguments: [
        (BluetoothPhotoFormat.spectra6, 1200, 1600, 960_000, UInt8(0x11)),
        (.gray4, 1872, 1404, 1_314_144, UInt8(0xff))
    ])
    func nativeFrameHasExpectedSizeAndNoImplicitTranspose(format: BluetoothPhotoFormat,
        width: Int, height: Int, bytes: Int, white: UInt8) throws {
        let c = try Self.capabilities(format: format, width: width, height: height)
        let pixels = Data(repeating: 255, count: width * height * 4)
        let packed = try BluetoothPhotoEncoder.encode(rgba: pixels, capabilities: c, dither: false)
        #expect(packed.count == bytes)
        #expect(packed.allSatisfy { $0 == white })
        #expect(c.panel.width == width)
        #expect(c.panel.height == height)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_BLE_PHOTO_INTEROP_DIR"] != nil))
    func exportsE1003GrayFrameForFirmwareReceiverInteroperability() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["TESSERAE_BLE_PHOTO_INTEROP_DIR"])
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let c = try JSONDecoder().decode(BluetoothPhotoCapabilities.self,
            from: Data(contentsOf: root.appendingPathComponent("e1003.capabilities.json")))
        try c.validate()
        #expect(c.kind == "seeed_reterminal_e1003")
        #expect(c.width == 1872 && c.height == 1404)
        #expect(c.format == .gray4 && c.stride == 936 && c.bytes == 1_314_144)
        #expect(c.digest == "324dcf85431b812a6c469bd3649552b41533155ddfb2bb5f7561d5d12f7d82f6")
        var pixels = [UInt8](repeating: 255, count: c.visibleWidth * c.visibleHeight * 4)
        for y in 0..<c.visibleHeight {
            for x in 0..<c.visibleWidth {
                // Odd-width blocks exercise high/low-nibble boundaries; the
                // vertical shift detects accidental mirroring or row reversal.
                let gray = UInt8(((x / 117 + y / 78) % 16) * 17)
                let p = (y * c.visibleWidth + x) * 4
                pixels[p] = gray; pixels[p + 1] = gray; pixels[p + 2] = gray
            }
        }
        let encoded = try BluetoothPhotoEncoder.encode(rgba: Data(pixels), capabilities: c)
        #expect(encoded.count == 1_314_144)
        let sha = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        #expect(sha == "c1a3309bcaf1663b33c035132dfcf44faf61c154fca304f037b1c2444fb9de1b")
        try encoded.write(to: root.appendingPathComponent("swift-e1003.bin"))
        try sha.write(to: root.appendingPathComponent("swift-e1003.sha256"), atomically: true, encoding: .utf8)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_BLE_PHOTO_INTEROP_DIR"] != nil))
    func exportsFrameForFirmwareReceiverInteroperability() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["TESSERAE_BLE_PHOTO_INTEROP_DIR"])
        let root = URL(fileURLWithPath: folder, isDirectory: true)
        let c = try JSONDecoder().decode(BluetoothPhotoCapabilities.self,
            from: Data(contentsOf: root.appendingPathComponent("e1004.capabilities.json")))
        try c.validate()
        #expect(c.width == 1200)
        #expect(c.height == 1600)
        #expect(c.format == .spectra6)
        #expect(c.digest == "e4a1365bc0232bd2666dbd403055fa710ab6cbe60cf2eaa2805140a7ea5f0f3f")
        let inks = c.format.palette
        var pixels = [UInt8](repeating: 255, count: c.visibleWidth * c.visibleHeight * 4)
        for y in 0..<c.visibleHeight {
            for x in 0..<c.visibleWidth {
                let ink = inks[(x / 200 + y / 200) % 6]
                let p = (y * c.visibleWidth + x) * 4
                pixels[p] = ink.red; pixels[p + 1] = ink.green; pixels[p + 2] = ink.blue
            }
        }
        let encoded = try BluetoothPhotoEncoder.encode(rgba: Data(pixels), capabilities: c)
        try encoded.write(to: root.appendingPathComponent("swift-e1004.bin"))
        let sha = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        #expect(encoded.count == 960_000)
        // Independently packed from the six sparse controller codes.
        #expect(sha == "7e88b3db01f7e8c6b66ad4111ca47e48c891a5ff785e07fe33d3566455af2404")
        try sha.write(to: root.appendingPathComponent("swift-e1004.sha256"), atomically: true, encoding: .utf8)
    }
}
