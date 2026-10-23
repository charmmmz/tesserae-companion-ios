import Foundation
import Testing
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

struct BluetoothPhotoV2Tests {
    static func capabilities(width: Int = 4, height: Int = 2, chunk: Int = 3,
                             window: Int? = nil) throws -> BluetoothPhotoCapabilities {
        var object: [String: Any] = ["schema": 2, "kind": "test_panel", "width": width, "height": height,
            "visible_width": width, "visible_height": height, "x_offset": 0, "format": "bwry2-msb",
            "stride": (width + 3) / 4, "bytes": ((width + 3) / 4) * height, "chunk_bytes": chunk,
            "digest": String(repeating: "b", count: 64), "row_order": "top_down", "lifecycle": "manual"]
        if let window { object["max_window"] = window }
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

    @Test func cumulativeAcknowledgementsRefillOnlyTheFreeWindow() throws {
        let caps = try Self.capabilities(width: 32, height: 2, chunk: 3, window: 4)
        var transfer = try BLEPhotoTransfer(data: Data(0..<16), id: 0x01020304, capabilities: caps)
        #expect(transfer.isAwaitingBegin)
        #expect(transfer.nextPackets().isEmpty)
        #expect(transfer.retryPackets().isEmpty)
        #expect(try transfer.acknowledge(0))
        #expect(!transfer.isAwaitingBegin)
        #expect(!((try transfer.acknowledge(0)))) // Begin is accepted only once.

        let first = transfer.nextPackets()
        #expect(first.map { $0[7] } == [0, 3, 6, 9])
        #expect(transfer.expectedOffset == 12)
        #expect(transfer.outstandingPacketCount == 4)
        #expect(transfer.nextPackets().isEmpty)
        #expect(!transfer.waitingForReceipt)
        #expect(transfer.retryPackets() == first)

        // Losing the notification for offset 3 does not stall a cumulative ACK.
        #expect(try transfer.acknowledge(6))
        #expect(transfer.offset == 6)
        #expect(transfer.outstandingPacketCount == 2)
        let last = transfer.nextPackets()
        #expect(last.map { $0[7] } == [12, 15])
        #expect(last.last == Data([1, 2, 3, 4, 0, 0, 0, 15, 15]))
        #expect(transfer.expectedOffset == 16)
        #expect(transfer.outstandingPacketCount == 4)
        #expect(transfer.nextPacket() == nil)
        #expect(!transfer.waitingForReceipt) // All sent still needs all ACKs.
        #expect(transfer.retryPackets() == Array(first.suffix(2)) + last)
        #expect(!((try transfer.acknowledge(3))))
        #expect(!((try transfer.acknowledge(6))))
        #expect(transfer.offset == 6)
        #expect(try transfer.acknowledge(12))
        #expect(transfer.retryPackets() == last)
        #expect(!transfer.waitingForReceipt)
        #expect(try transfer.acknowledge(16))
        #expect(transfer.waitingForReceipt)
        #expect(transfer.retryPackets().isEmpty)
        #expect(transfer.nextPackets().isEmpty)
        #expect(!((try transfer.acknowledge(16))))
    }

    @Test(arguments: [-1, 1, 4, 13, 16, 17])
    func rejectsUnsentOrUnalignedAcknowledgements(value: Int) throws {
        let caps = try Self.capabilities(width: 32, height: 2, chunk: 3, window: 4)
        var transfer = try BLEPhotoTransfer(data: Data(0..<16), id: 1, capabilities: caps)
        #expect(try transfer.acknowledge(0))
        #expect(transfer.nextPackets().count == 4) // Sent through offset 12.
        #expect(throws: (any Error).self) { try transfer.acknowledge(value) }
        #expect(transfer.offset == 0 && transfer.expectedOffset == 12)
    }

    @Test func staleAcknowledgementsMustStillBePacketBoundaries() throws {
        let caps = try Self.capabilities(width: 32, height: 2, chunk: 3, window: 4)
        var transfer = try BLEPhotoTransfer(data: Data(0..<16), id: 1, capabilities: caps)
        #expect(try transfer.acknowledge(0))
        #expect(transfer.nextPackets().count == 4)
        #expect(try transfer.acknowledge(9))
        #expect(!((try transfer.acknowledge(3))))
        #expect(throws: (any Error).self) { try transfer.acknowledge(4) }
        #expect(transfer.offset == 9)
    }

    @Test(arguments: [nil, 1, 2, 3, 4] as [Int?])
    func respectsNegotiatedWindowAndRetainsExactRetryPackets(window: Int?) throws {
        let caps = try Self.capabilities(width: 32, height: 2, chunk: 3, window: window)
        var transfer = try BLEPhotoTransfer(data: Data(0..<16), id: 1, capabilities: caps)
        #expect(try transfer.acknowledge(0))
        let packets = transfer.nextPackets()
        #expect(transfer.windowSize == (window ?? 1))
        #expect(packets.count == (window ?? 1))
        #expect(transfer.nextPackets().isEmpty)
        #expect(transfer.retryPackets() == packets)
        #expect(transfer.offset == 0)
    }

    @Test func legacyPicPakRemainsOnePacketAtATime() throws {
        var transfer = try BLEPhotoTransfer(data: Data(repeating: 0x1b, count: 30_000), id: 1)
        #expect(transfer.windowSize == 1)
        #expect(try transfer.acknowledge(0))
        let packets = transfer.nextPackets()
        #expect(packets.count == 1 && packets[0].count == 200)
        #expect(transfer.nextPackets().isEmpty)
        #expect(transfer.retryPackets() == packets)
        #expect(try transfer.acknowledge(192))
        #expect(transfer.nextPackets().count == 1)
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

    @Test func e1003GrayFrameEndsWithANinetySixByteChunk() throws {
        let json = """
        {"schema":2,"kind":"seeed_reterminal_e1003","width":1872,"height":1404,
        "visible_width":1872,"visible_height":1404,"x_offset":0,"format":"gray4-msb",
        "stride":936,"bytes":1314144,"chunk_bytes":384,
        "digest":"324dcf85431b812a6c469bd3649552b41533155ddfb2bb5f7561d5d12f7d82f6",
        "row_order":"top_down","lifecycle":"manual"}
        """
        let caps = try JSONDecoder().decode(BluetoothPhotoCapabilities.self, from: Data(json.utf8))
        var transfer = try BLEPhotoTransfer(data: Data(repeating: 0xab, count: 1_314_144),
                                          id: 0x01020304, capabilities: caps)
        #expect(try transfer.acknowledge(0))
        var chunks = 0
        for offset in stride(from: 0, to: 1_314_144, by: 384) {
            let nextPacket = transfer.nextPacket()
            let packet = try #require(nextPacket)
            if offset == 1_314_048 {
                #expect(packet.prefix(8) == Data([1, 2, 3, 4, 0, 20, 13, 0]))
                #expect(packet.count == 104) // 8-byte header + 96 pixel bytes
            }
            #expect(try transfer.acknowledge(offset + packet.count - 8))
            chunks += 1
        }
        #expect(chunks == 3423)
        #expect(transfer.nextPacket() == nil)
        #expect(transfer.waitingForReceipt)
    }
}
