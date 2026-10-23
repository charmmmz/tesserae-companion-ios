import Foundation
import Testing
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
struct BluetoothDisplayStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func display(id: String = "panel", percent: Int? = 73, seen: Date? = nil) -> DisplaySummary {
        DisplaySummary(id: id, name: "Desk", kind: "test_panel", iconName: "display",
            panel: PanelProfile(width: 4, height: 2, gamut: "bwry_4", orientation: "landscape"),
            freshness: .stale, lastSeenAt: seen, batteryPercent: percent)
    }

    @Test func recordsSurviveRestartAndUnconfirmedWorkCannotReplaceTheImage() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start)
        let png = try LocalBluetoothPhotoRenderer.previewPNG(frame: Data(repeating: 0x1b, count: 30000), capabilities: nil)
        store.receivedPhoto(deviceID: "panel", previewPNG: png, at: start)
        // New diagnostics, missing battery values, and an empty preview cannot erase the last received image.
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: 0, at: start.addingTimeInterval(1))
        store.receivedPhoto(deviceID: "panel", previewPNG: Data())
        let restored = BluetoothDisplayStore(fileURL: file)
        let record = try #require(restored.record(for: "panel", serverID: "home"))
        #expect(record.mode == .bluetooth)
        #expect(record.modeConfirmedAt == start)
        #expect(record.batteryMillivolts == 3900)
        #expect(record.previewPNG == png)
        #expect(record.photoReceivedAt == start)
        #expect(restored.storageError == nil)
    }

    @Test func identitiesRequireExactIDsOrAnExplicitServerScopedLink() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "picpak-aabbcc112233", name: "Kitchen", mode: .bluetooth, batteryMillivolts: nil)
        #expect(store.record(for: "picpak-112233", serverID: "home") == nil)
        #expect(store.record(for: "picpak-aabbcc112233", serverID: "other") == nil)
        store.link("picpak-aabbcc112233", to: "picpak-112233", serverID: "home")
        #expect(store.record(for: "picpak-112233", serverID: "home")?.mode == .bluetooth)
        #expect(store.record(for: "picpak-aabbcc112233", serverID: "home") == nil)
        store.link("picpak-aabbcc112233", to: "different", serverID: "home")
        #expect(store.record(for: "picpak-112233", serverID: "home") == nil)
        store.link(nil, to: "different", serverID: "home")
        #expect(store.record(for: "different", serverID: "home") == nil)
    }

    @Test func batteryKeepsTheLastPercentageAndItsTimeWithoutInventingOneFromVoltage() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observeServer(displays: [display(seen: start)], previews: [:], serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start.addingTimeInterval(20))
        store.observeServer(displays: [display(percent: nil)], previews: [:], serverID: "home")
        store.observeServer(displays: [display(percent: 90, seen: start.addingTimeInterval(-10))], previews: [:], serverID: "home")
        let value = store.presentation(for: display(percent: nil), serverID: "home")
        #expect(value.batteryText == "73%")
        #expect(value.batteryDate == start)
        #expect(value.voltageText != nil)
        #expect(store.presentation(for: display(percent: nil), serverID: "other").batteryText == "—")
    }

    @Test func wifiNeedsBothANewerHeartbeatAndAChangedServerPreview() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        func preview(_ token: String) -> [String: PreviewImageState] {
            ["panel": PreviewImageState(data: Data([1]), eTag: token, phase: .ready)]
        }
        store.observeServer(displays: [display(seen: start)], previews: preview("old"), serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        store.receivedPhoto(deviceID: "panel", previewPNG: Data([2]), at: start)
        let resumed = start.addingTimeInterval(30)
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: resumed)
        func usesLocal() -> Bool { store.presentation(for: display(), serverID: "home").usesLocalPreview }
        store.observeServer(displays: [display(seen: start)], previews: preview("old"), serverID: "home", at: resumed.addingTimeInterval(1))
        #expect(usesLocal())
        store.observeServer(displays: [display(seen: start)], previews: preview("new"), serverID: "home", at: resumed.addingTimeInterval(2))
        #expect(usesLocal())
        store.observeServer(displays: [display(seen: resumed.addingTimeInterval(3))], previews: preview("new"), serverID: "home", at: resumed.addingTimeInterval(3))
        #expect(!usesLocal())
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: resumed.addingTimeInterval(10))
        #expect(!usesLocal()) // Same-mode readback does not move the recovery boundary.
        #expect(store.record(for: "panel", serverID: "home")?.modeConfirmedAt == resumed.addingTimeInterval(10))
        // Missing or older heartbeat fields cannot bring an obsolete Bluetooth image back.
        store.observeServer(displays: [display(seen: nil)], previews: [:], serverID: "home")
        #expect(!usesLocal())
        store.observeServer(displays: [display(seen: start)], previews: [:], serverID: "home")
        #expect(!usesLocal())
        // A later photo without a mode field still takes priority over earlier Wi-Fi evidence.
        store.receivedPhoto(deviceID: "panel", previewPNG: Data([3]), at: resumed.addingTimeInterval(20))
        #expect(usesLocal())
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: resumed.addingTimeInterval(25))
        #expect(usesLocal())
        store.observeServer(displays: [display(seen: resumed.addingTimeInterval(30))], previews: preview("newer"),
                            serverID: "home", at: resumed.addingTimeInterval(30))
        #expect(!usesLocal())
        store.remove(deviceID: "panel")
        #expect(store.record(for: "panel", serverID: "home") == nil)
    }

    @Test func previewsDecodeQuantizedColorsAndPicPakBottomUpRows() throws {
        let caps = try BluetoothPhotoV2Tests.capabilities()
        let png = try LocalBluetoothPhotoRenderer.previewPNG(frame: Data([0x1b, 0xe4]), capabilities: caps)
        #expect(try pixels(png) == [0,0,0,255, 255,255,255,255, 255,255,0,255, 255,0,0,255,
                                    255,0,0,255, 255,255,0,255, 255,255,255,255, 0,0,0,255])
        var frame = Data(repeating: 0, count: 30000)
        frame.replaceSubrange(0..<100, with: repeatElement(UInt8(0xff), count: 100))
        let legacy = try LocalBluetoothPhotoRenderer.previewPNG(frame: frame, capabilities: nil)
        let decoded = try pixels(legacy)
        #expect(Array(decoded.prefix(4)) == [0,0,0,255])
        #expect(Array(decoded.suffix(4)) == [255,0,0,255])
    }

    @Test func previewOmitsHiddenColumnsAndRejectsTruncatedFrames() throws {
        let original = try BluetoothPhotoV2Tests.capabilities()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json["visible_width"] = 2
        json["x_offset"] = 1
        let caps = try JSONDecoder().decode(BluetoothPhotoCapabilities.self, from: JSONSerialization.data(withJSONObject: json))
        let png = try LocalBluetoothPhotoRenderer.previewPNG(frame: Data([0x1b, 0x1b]), capabilities: caps)
        #expect(try pixels(png) == [255,255,255,255, 255,255,0,255, 255,255,255,255, 255,255,0,255])
        #expect(throws: BluetoothPhotoError.invalidPixels) {
            try LocalBluetoothPhotoRenderer.previewPNG(frame: Data([0x1b]), capabilities: caps)
        }
    }

    private func pixels(_ png: Data) throws -> [UInt8] {
        let image = try #require(UIImage(data: png)?.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &bytes, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
