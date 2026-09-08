import XCTest
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

final class BLEPhotoTests: XCTestCase {
    func testPhotoStatusParsesFirmwareReplyWithoutChangingTransferContract() throws {
        let data = Data("""
        {"event":"photo_info","version":1,"width":400,"height":300,"bytes":30000,
         "chunk_bytes":192,"format":"picpak-bwry2-bottom-up","battery_mv":3900,
         "low_battery":false,"refresh_speed":"5s","screen_mode":"bluetooth"}
        """.utf8)
        let event = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let status = BLEPhotoDeviceStatus(event: event)
        XCTAssertEqual(status.batteryMillivolts, 3900)
        XCTAssertEqual(status.lowBattery, false)
        XCTAssertEqual(status.refreshSpeed, .fiveSeconds)
        XCTAssertEqual(status.screenMode, .bluetooth)
        XCTAssertEqual(event["bytes"] as? Int, BLEPhotoTransfer.byteCount)
    }

    func testPhotoStatusKeepsMissingAndInvalidValuesUnknown() {
        let legacy = BLEPhotoDeviceStatus(event: [:])
        XCTAssertNil(legacy.batteryMillivolts)
        XCTAssertNil(legacy.batteryText)
        XCTAssertNil(legacy.lowBattery)
        XCTAssertNil(legacy.refreshSpeed)
        XCTAssertNil(legacy.screenMode)
        for value in [NSNull(), -1, 0, 2499, 5001, 3900.5, true, "3900"] as [Any] {
            let status = BLEPhotoDeviceStatus(event: ["battery_mv": value, "low_battery": true,
                                                      "refresh_speed": "future", "screen_mode": "future"])
            XCTAssertNil(status.batteryMillivolts)
            XCTAssertNil(status.lowBattery)
            XCTAssertNil(status.refreshSpeed)
            XCTAssertNil(status.screenMode)
        }
    }

    func testPhotoStatusUsesDeviceLowBatteryFlagAndSupportsAllRefreshSpeeds() {
        let low = BLEPhotoDeviceStatus(event: ["battery_mv": 3350, "low_battery": true,
                                               "refresh_speed": "native", "screen_mode": "wifi"])
        XCTAssertEqual(low.lowBattery, true)
        XCTAssertEqual(low.refreshSpeed, .native)
        XCTAssertEqual(low.screenMode, .wifi)
        let incomplete = BLEPhotoDeviceStatus(event: ["battery_mv": 3350, "refresh_speed": "10s"])
        XCTAssertNil(incomplete.lowBattery) // Do not invent a warning for older firmware.
        XCTAssertEqual(incomplete.refreshSpeed, .tenSeconds)
        XCTAssertNil(BLEPhotoDeviceStatus(event: ["battery_mv": 3900, "low_battery": 1]).lowBattery)
    }

    func testTransferRejectsWrongSizesAndOutOfOrderAcknowledgements() throws {
        XCTAssertThrowsError(try BLEPhotoTransfer(data: Data(count: 29999), id: 1))
        XCTAssertThrowsError(try BLEPhotoTransfer(data: Data(count: 30000), id: 0))
        var transfer = try BLEPhotoTransfer(data: Data(repeating: 0x1b, count: 30000), id: 0x01020304)
        XCTAssertThrowsError(try transfer.acknowledge(192))
        XCTAssertTrue(try transfer.acknowledge(0))
        let packet = try XCTUnwrap(transfer.nextPacket())
        XCTAssertEqual(packet.count, 200)
        XCTAssertEqual(packet.prefix(9), Data([1,2,3,4,0,0,0,0,0x1b]))
        XCTAssertFalse(try transfer.acknowledge(0)) // stale ACK cannot send another chunk
        XCTAssertThrowsError(try transfer.acknowledge(193))
        XCTAssertTrue(try transfer.acknowledge(192))
        while let packet = transfer.nextPacket() {
            XCTAssertLessThanOrEqual(packet.count, 200)
            XCTAssertTrue(try transfer.acknowledge(transfer.expectedOffset))
        }
        XCTAssertTrue(transfer.waitingForReceipt)
        XCTAssertEqual(transfer.offset, 30000)
        XCTAssertFalse(try transfer.acknowledge(30000))
    }

    @MainActor
    func testPhotoKeychainRoundTripAndRevocation() throws {
        let id = "test-photo-" + UUID().uuidString
        let key = Data(repeating: 0x5a, count: 32)
        defer { BLEPhotoKeyStore.remove(id) }
        XCTAssertNil(BLEPhotoKeyStore.read(id))
        try BLEPhotoKeyStore.save(key, for: id)
        XCTAssertEqual(BLEPhotoKeyStore.read(id), key)
        let replacement = Data(repeating: 0xa5, count: 32)
        try BLEPhotoKeyStore.save(replacement, for: id)
        XCTAssertEqual(BLEPhotoKeyStore.read(id), replacement)
        BLEPhotoKeyStore.remove(id)
        XCTAssertNil(BLEPhotoKeyStore.read(id))
    }

    func testPhotoAdvertisementIsDistinctAndOldFirmwareHasNoModePicker() throws {
        let ad = try XCTUnwrap(BLESetupAdvertisement(serviceData: Data([2,4,11,1,2,3,4,5,6,7])))
        XCTAssertEqual(ad.mode, .photo)
        XCTAssertNotEqual(BLESetupProtocol.photoServiceUUID, BLESetupProtocol.serviceUUID)
        XCTAssertNil(NearbyDeviceDiagnostics(event: ["refresh_speed": "5s"]).screenMode)
        XCTAssertEqual(NearbyDeviceDiagnostics(event: ["screen_mode": "bluetooth"]).screenMode, .bluetooth)
        XCTAssertNil(NearbyDeviceDiagnostics(event: ["screen_mode": "future-mode"]).screenMode)
    }

    func testPixelPackingPreservesPaletteAndBottomUpRows() throws {
        let palette: [[UInt8]] = [[0,0,0,255], [255,255,255,255], [255,255,0,255], [255,0,0,255]]
        var pixels = Data()
        for y in 0..<300 { for x in 0..<400 {
            pixels.append(contentsOf: palette[y == 299 ? 3 - (x % 4) : x % 4])
        } }
        let packed = try PicPakPhotoEncoder.encode(rgba: pixels)
        XCTAssertEqual(packed.count, 30000)
        XCTAssertEqual(packed.prefix(100), Data(repeating: 0xe4, count: 100))
        XCTAssertEqual(packed.suffix(100), Data(repeating: 0x1b, count: 100))
        XCTAssertThrowsError(try PicPakPhotoEncoder.encode(rgba: Data(count: 4)))
    }

    @MainActor
    func testRasterOrientationAndCropMatchThePreview() throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 300), format: format).image { c in
            UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 800, height: 150))
            UIColor.yellow.setFill(); c.fill(CGRect(x: 0, y: 150, width: 800, height: 150))
        }
        let raster = try PicPakPhotoEncoder.raster(image: image, fit: .fill, framing: .centeredFill)
        let packed = try PicPakPhotoEncoder.encode(rgba: raster)
        XCTAssertEqual(packed.prefix(100), Data(repeating: 0xaa, count: 100)) // bottom = yellow
        XCTAssertEqual(packed.suffix(100), Data(repeating: 0xff, count: 100)) // top = red
        let halves = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 300), format: format).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            UIColor.black.setFill(); c.fill(CGRect(x: 400, y: 0, width: 400, height: 300))
        }
        let right = try PicPakPhotoEncoder.raster(image: halves, fit: .fill,
                                                 framing: .init(focusX: 1, focusY: 0.5, zoom: 1))
        XCTAssertEqual(try PicPakPhotoEncoder.encode(rgba: right), Data(count: 30000))
    }
}
