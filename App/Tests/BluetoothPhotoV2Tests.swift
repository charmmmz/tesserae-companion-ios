import Foundation
import Testing
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

struct BluetoothPhotoV2Tests {
    static func capabilities(width: Int = 4, height: Int = 2, chunk: Int = 3) throws -> BluetoothPhotoCapabilities {
        let object: [String: Any] = ["schema": 2, "kind": "test_panel", "width": width, "height": height,
            "visible_width": width, "visible_height": height, "x_offset": 0, "format": "bwry2-msb",
            "stride": (width + 3) / 4, "bytes": ((width + 3) / 4) * height, "chunk_bytes": chunk,
            "digest": String(repeating: "b", count: 64), "row_order": "top_down", "lifecycle": "manual"]
        return try JSONDecoder().decode(BluetoothPhotoCapabilities.self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test(arguments: [
        (UInt8(8), "reTerminal_Sticky", BLESetupHardware.seeedSticky),
        (UInt8(8), "seeed_xiao_75", .seeedXIAO75),
        (UInt8(9), "Seeed_EE05_213_BWRY", .seeedEE05),
        (UInt8(9), "waveshare_133e6", .waveshare133E6),
        (UInt8(11), "Seeed_EE03", .seeedEE03),
        (UInt8(11), "picpak_4_2", .picPak42),
        (UInt8(12), "PaperMono", .paperMono),
        (UInt8(18), "GoodDisplay_ESP32_133C02", .goodDisplay133),
        (UInt8(19), "Inkplate_13SPECTRA", .inkplate13)
    ])
    func resolvesConflictingNumbersOnlyWithModel(code: UInt8, model: String, hardware: BLESetupHardware) {
        #expect(BLESetupHardware.resolve(code: code, model: model) == hardware)
    }

    @Test func unknownAndMismatchedModelsNeverGetPicPakControls() {
        #expect(BLESetupHardware.resolve(code: 11, model: "future_panel") == .unknown(11))
        #expect(BLESetupHardware.resolve(code: 4, model: "picpak_4_2") == .unknown(4))
        #expect(BLESetupHardware.resolve(code: 11, model: "Seeed_EE03") != .picPak42)
        #expect(BLESetupAdvertisement(serviceData: Data([2,2,11,0,0,1,0,0,0,1]))?.hardware == .unknown(11))
    }

    @Test func negotiatedTransferHasItsOwnSizeAndChunkBoundary() throws {
        let caps = try Self.capabilities(width: 16, height: 2, chunk: 3)
        var transfer = try BLEPhotoTransfer(data: Data(0..<8), id: 0x01020304, capabilities: caps)
        #expect(try transfer.acknowledge(0))
        #expect(transfer.nextPacket() == Data([1,2,3,4,0,0,0,0,0,1,2]))
        #expect(!((try transfer.acknowledge(0))))
        #expect(throws: (any Error).self) { try transfer.acknowledge(4) }
        #expect(try transfer.acknowledge(3))
        #expect(transfer.nextPacket() == Data([1,2,3,4,0,0,0,3,3,4,5]))
        #expect(try transfer.acknowledge(6))
        #expect(transfer.nextPacket() == Data([1,2,3,4,0,0,0,6,6,7]))
        #expect(try transfer.acknowledge(8))
        #expect(transfer.nextPacket() == nil)
        #expect(transfer.waitingForReceipt)
        #expect(throws: (any Error).self) {
            try BLEPhotoTransfer(data: Data(count: 30_000), id: 1, capabilities: caps)
        }
    }

    @Test @MainActor func rasterPreservesTopAndBottomMarkers() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 2), format: format).image { c in
            UIColor.yellow.setFill(); c.fill(CGRect(x: 0, y: 0, width: 4, height: 1))
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 1, width: 4, height: 1))
        }
        let caps = try Self.capabilities()
        let rgba = try LocalBluetoothPhotoRenderer.raster(image: image, fit: .fit,
            framing: ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 1), capabilities: caps)
        #expect(try BluetoothPhotoEncoder.encode(rgba: rgba, capabilities: caps, dither: false) == Data([0xaa, 0xff]))
    }
}
