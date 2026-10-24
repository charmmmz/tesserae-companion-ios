import Foundation
import Testing
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
struct BluetoothDisplayStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func display(id: String = "panel", percent: Int? = 73, seen: Date? = nil, mac: String? = nil) -> DisplaySummary {
        DisplaySummary(id: id, name: "Desk", kind: "test_panel", iconName: "display",
            panel: PanelProfile(width: 4, height: 2, gamut: "bwry_4", orientation: "landscape"),
            freshness: .stale, lastSeenAt: seen, batteryPercent: percent, mac: mac)
    }

    @Test func recordsSurviveRestartAndUnconfirmedWorkCannotReplaceTheImage() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start)
        let png = try LocalBluetoothPhotoRenderer.previewPNG(rgba: Data([20, 100, 180, 255]), width: 1, height: 1)
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

    @Test func confirmedWiFiImmediatelyRestoresServerPreviewEvenWhenUnchanged() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        func preview(_ token: String) -> [String: PreviewImageState] {
            ["panel": PreviewImageState(data: Data([1]), eTag: token, phase: .ready)]
        }
        store.observeServer(displays: [display(seen: start)], previews: preview("old"), serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        store.receivedPhoto(deviceID: "panel", previewPNG: Data([2]), at: start)
        #expect(store.presentation(for: display(), serverID: "home").usesLocalPreview)
        // No acknowledged mode change: interrupted or failed work keeps the photo.
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: nil,
                      at: start.addingTimeInterval(1))
        #expect(store.presentation(for: display(), serverID: "home").usesLocalPreview)
        let resumed = start.addingTimeInterval(30)
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: resumed)
        func usesLocal() -> Bool { store.presentation(for: display(), serverID: "home").usesLocalPreview }
        #expect(!usesLocal()) // No new heartbeat, image change or subsequent server fetch required.
        #expect(store.record(for: "panel", serverID: "home")?.previewPNG == nil)
        store.observeServer(displays: [display(seen: start)], previews: preview("old"), serverID: "home", at: resumed.addingTimeInterval(1))
        #expect(!usesLocal())
        store.observeServer(displays: [display(seen: start)], previews: preview("new"), serverID: "home", at: resumed.addingTimeInterval(2))
        #expect(!usesLocal())
        store.observeServer(displays: [display(seen: resumed.addingTimeInterval(3))], previews: preview("new"), serverID: "home", at: resumed.addingTimeInterval(3))
        #expect(!usesLocal())
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: resumed.addingTimeInterval(10))
        #expect(!usesLocal())
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
        #expect(!usesLocal())
        store.observeServer(displays: [display(seen: resumed.addingTimeInterval(30))], previews: preview("newer"),
                            serverID: "home", at: resumed.addingTimeInterval(30))
        #expect(!usesLocal())
        store.remove(deviceID: "panel")
        #expect(store.record(for: "panel", serverID: "home") == nil)
    }

    @Test(arguments: [false, true])
    func startupReclaimsOldWiFiThumbnailsButPreservesLaterPhotos(photoAfterWiFi: Bool) throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start)
        store.receivedPhoto(deviceID: "panel", previewPNG: Data([2]), at: start)
        // Reproduce an on-disk record created before the Wi-Fi cache fix.
        var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        var records = try #require(plist["records"] as? [String: [String: Any]])
        var record = try #require(records["panel"])
        record["mode"] = "wifi"
        record["modeConfirmedAt"] = start.addingTimeInterval(30)
        record["modeChangedAt"] = start.addingTimeInterval(30)
        record["photoReceivedAt"] = photoAfterWiFi ? start.addingTimeInterval(40) : start
        records["panel"] = record
        plist["records"] = records
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)

        let restored = BluetoothDisplayStore(fileURL: file)
        let value = restored.presentation(for: display(), serverID: "home")
        #expect(value.usesLocalPreview == photoAfterWiFi)
        #expect((value.record?.previewPNG != nil) == photoAfterWiFi)
        #expect(value.record?.mode == .wifi)
        #expect(value.record?.batteryMillivolts == 3900)
        let reloaded = BluetoothDisplayStore(fileURL: file)
        #expect(reloaded.presentation(for: display(), serverID: "home").usesLocalPreview == photoAfterWiFi)
    }

    @Test func fullMACAutomaticallyAssociatesAndMarksOnlyConfirmedBluetoothMode() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BluetoothDisplayStore(fileURL: file)
        // A maintenance session may happen before connecting to a server.
        let info = try JSONDecoder().decode(BLESetupDeviceInfo.self, from: Data(#"{"protocol":2,"id":"picpak-f85b1b4fe844","sid":"01020304","connection_nonce":"000102030405060708090a0b0c0d0e0f","hardware":20,"model":"picpak_4_2","firmware":"0.9.10","mode":"maintenance"}"#.utf8))
        #expect(info.hardwareMAC == "f8:5b:1b:4f:e8:44")
        store.observe(deviceID: info.id, name: "Nearby", mode: nil, batteryMillivolts: nil, hardwareMAC: info.hardwareMAC)
        let target = display(id: "renamed-red-frame", mac: "F8-5B-1B-4F-E8-44")
        store.observeServer(displays: [target], previews: [:], serverID: "home")
        #expect(!store.presentation(for: target, serverID: "home").isBluetooth)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Nearby", mode: .bluetooth,
                      batteryMillivolts: 4100, at: start)
        #expect(store.presentation(for: target, serverID: "home").isBluetooth)
        #expect(store.presentation(for: target, serverID: "home").lastSeenAt(fallback: nil) == start)
        #expect(store.record(for: target.id, serverID: "other") == nil)
        let restored = BluetoothDisplayStore(fileURL: file)
        #expect(restored.presentation(for: target, serverID: "home").isBluetooth)
    }

    @Test func MACAssociationRejectsAmbiguityAndRespectsManualOverrides() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Frame", mode: .bluetooth, batteryMillivolts: nil)
        let target = display(id: "red", mac: "f8:5b:1b:4f:e8:44")
        let duplicate = display(id: "duplicate", mac: "f85b1b4fe844")
        store.observeServer(displays: [target, duplicate], previews: [:], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.observeServer(displays: [target], previews: [:], serverID: "home")
        #expect(store.record(for: "red", serverID: "home")?.mode == .bluetooth)
        store.link(nil, to: "red", serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.link("picpak-f85b1b4fe844", to: "different", serverID: "elsewhere")
        #expect(store.record(for: "red", serverID: "home") == nil)

        let ambiguous = BluetoothDisplayStore(fileURL: nil)
        ambiguous.observeServer(displays: [target], previews: [:], serverID: "home")
        for id in ["first", "second"] {
            ambiguous.observe(deviceID: id, name: "Frame", mode: .bluetooth, batteryMillivolts: nil,
                              hardwareMAC: target.mac)
        }
        #expect(ambiguous.record(for: "red", serverID: "home") == nil)
    }

    @Test func shortMACSuffixCannotAutomaticallyAssociate() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "picpak-4fe844", name: "Red", mode: .bluetooth, batteryMillivolts: nil)
        store.observeServer(displays: [display(id: "red", mac: "f8:5b:1b:4f:e8:44")], previews: [:], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
    }

    @Test func canonicalServerIDsRemainCompatibleWithNativeFirmware() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "native-panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil)
        store.observeServer(displays: [display(id: "native-panel", mac: "f8:5b:1b:4f:e8:44")],
                            previews: [:], serverID: "home")
        #expect(store.record(for: "native-panel", serverID: "home")?.mode == .bluetooth)
        #expect(store.record(for: "native-panel", serverID: "other") == nil)
    }

    @Test func bindingControlsDisappearAfterAssociationAndRejectConflictingMACs() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Red", mode: .bluetooth, batteryMillivolts: nil)
        store.observe(deviceID: "picpak-f85b1b4f0700", name: "Blue", mode: .bluetooth, batteryMillivolts: nil)
        #expect(store.manualLinkCandidates(for: "legacy", serverID: "home").count == 2)
        store.link("picpak-f85b1b4fe844", to: "legacy", serverID: "home")
        #expect(store.manualLinkCandidates(for: "legacy", serverID: "home").isEmpty)

        // Complete hardware evidence repairs a historical manual mismatch without deleting the record.
        store.observeServer(displays: [display(id: "legacy", mac: "f8:5b:1b:4f:07:00")], previews: [:], serverID: "home")
        #expect(store.record(for: "legacy", serverID: "home")?.id == "picpak-f85b1b4f0700")
        #expect(store.manualLinkCandidates(for: "legacy", serverID: "home").isEmpty)
        store.link("picpak-f85b1b4fe844", to: "legacy", serverID: "home")
        #expect(store.record(for: "legacy", serverID: "home")?.id == "picpak-f85b1b4f0700")
        #expect(store.records.count == 2)
    }

    @Test func confirmedWiFiReclaimsPreviewButSleepingDisplaysKeepTheirState() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        let oldPreview = PreviewImageState(data: Data([1]), eTag: "old", phase: .ready)
        store.observeServer(displays: [display(seen: start)], previews: ["panel": oldPreview], serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start)
        store.receivedPhoto(deviceID: "panel", previewPNG: Data([2]), at: start)
        let later = start.addingTimeInterval(60 * 60 * 24 * 30)
        store.observeServer(displays: [display(seen: start)], previews: ["panel": oldPreview], serverID: "home", at: later)
        #expect(store.record(for: "panel", serverID: "home")?.previewPNG == Data([2]))
        #expect(store.record(for: "panel", serverID: "home")?.mode == .bluetooth)

        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: later)
        let restored = BluetoothDisplayStore(fileURL: file)
        #expect(restored.record(for: "panel", serverID: "home")?.mode == .wifi)
        #expect(restored.record(for: "panel", serverID: "home")?.previewPNG == nil)
        #expect(restored.record(for: "panel", serverID: "home")?.photoReceivedAt == nil)
        restored.remove(deviceID: "panel")
        #expect(restored.records.isEmpty)
        #expect(restored.record(for: "panel", serverID: "home") == nil)
    }

    @Test func rememberedHardwareIsOnlyAUniquePresentationHint() {
        let store = BluetoothDisplayStore(fileURL: nil)
        #expect(store.hardwareHint(code: 20, suffix: "4FE844") == nil)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Red", mode: nil, batteryMillivolts: nil)
        #expect(store.hardwareHint(code: 20, suffix: "4FE844") == .picPak42)
        #expect(store.hardwareHint(code: 8, suffix: "4FE844") == nil)
        #expect(store.records.first?.mode == nil)
        #expect(store.record(for: "unrelated", serverID: "home") == nil)
        store.observe(deviceID: "picpak-aabbcc4fe844", name: "Other", mode: nil, batteryMillivolts: nil)
        #expect(store.hardwareHint(code: 20, suffix: "4FE844") == nil)
        let ee03 = BluetoothDisplayStore(fileURL: nil)
        ee03.observe(deviceID: "ee03", name: "Seeed", mode: nil, batteryMillivolts: nil,
            hardwareMAC: "f8:5b:1b:4f:e8:44", hardwareKind: "seeed_ee03")
        #expect(ee03.hardwareHint(code: 11, suffix: "4FE844") == .seeedEE03)
    }

    @Test func originalThumbnailPreservesColoursRowsAndBoundedSize() throws {
        let rgba = Data([20, 100, 180, 255, 80, 160, 220, 255,
                         50, 120, 190, 255, 90, 170, 230, 255])
        let png = try LocalBluetoothPhotoRenderer.previewPNG(rgba: rgba, width: 2, height: 2)
        #expect(try pixels(png) == Array(rgba))
        let large = try LocalBluetoothPhotoRenderer.previewPNG(
            rgba: Data(repeating: 255, count: 1600 * 1200 * 4), width: 1600, height: 1200)
        let image = try #require(UIImage(data: large)?.cgImage)
        #expect(image.width == 760)
        #expect(image.height == 570)
        #expect(throws: BluetoothPhotoError.invalidPixels) {
            try LocalBluetoothPhotoRenderer.previewPNG(rgba: Data([0]), width: 2, height: 2)
        }
    }

    @Test func thumbnailMatchesTheSentFillCropAndFitBorders() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let source = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 300), format: format).image { ctx in
            UIColor(red: 0.1, green: 0.4, blue: 0.7, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 300))
            UIColor(red: 0.3, green: 0.6, blue: 0.8, alpha: 1).setFill()
            ctx.fill(CGRect(x: 400, y: 0, width: 400, height: 300))
        }
        for fit: ImageFitMode in [.fill, .fit] {
            let rgba = try PicPakPhotoEncoder.raster(image: source, fit: fit, framing: ImageFraming(focusX: 0.8, focusY: 0.5, zoom: 1))
            let png = try LocalBluetoothPhotoRenderer.previewPNG(rgba: rgba, width: 400, height: 300)
            #expect(try pixels(png) == Array(rgba))
            let decoded = try pixels(png)
            if fit == .fit {
                #expect(Array(decoded.prefix(4)) == [255, 255, 255, 255])
            } else {
                // Right-focused Fill excludes the blue left half of the original.
                #expect((70...85).contains(Int(decoded[0])))
                #expect((145...165).contains(Int(decoded[1])))
                #expect((195...215).contains(Int(decoded[2])))
            }
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
