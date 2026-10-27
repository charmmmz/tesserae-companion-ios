import Foundation
import Testing
import UIKit
import TesseraeKit
@testable import Tesserae_Companion

@MainActor
struct BluetoothDisplayStoreTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func statusReadingsSurviveRestartAndUpgradeAnAcknowledgedMode() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900,
            batteryPercent: 65, firmwareVersion: "0.9.11", at: start)
        let modeOnly = try #require(store.pendingModeReports(displayIDs: ["panel"], serverID: "home").first)
        #expect(modeOnly.observation.battery == nil)
        store.markModeReported(modeOnly, serverID: "home")
        let restored = BluetoothDisplayStore(fileURL: file)
        let status = try #require(restored.pendingModeReports(displayIDs: ["panel"], serverID: "home", includeStatus: true).first)
        #expect(status.observation.battery == .init(percent: 65, observedAt: start))
        #expect(status.observation.firmware == .init(version: "0.9.11", observedAt: start))
        restored.markModeReported(status, serverID: "home")
        let newer = start.addingTimeInterval(60)
        restored.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: nil,
            batteryPercent: 63, at: newer)
        // A delayed acknowledgement cannot suppress a reading collected in the meantime.
        restored.markModeReported(status, serverID: "home")
        let updated = try #require(restored.pendingModeReports(displayIDs: ["panel"], serverID: "home", includeStatus: true).first)
        #expect(updated.observation.observedAt == start)
        #expect(updated.observation.battery == .init(percent: 63, observedAt: newer))
        #expect(updated.observation.firmware?.observedAt == start)
        let data = try TesseraeJSON.encoder().encode(updated.observation)
        let decoded = try TesseraeJSON.decoder().decode(DeviceModeObservation.self, from: data)
        #expect(decoded == updated.observation)
        #expect(restored.pendingModeReports(displayIDs: ["other"], serverID: "home", includeStatus: true).isEmpty)
    }

    @Test func invalidOrOlderFirmwareCannotReplaceSavedVersion() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil,
            firmwareVersion: "0.9.11", at: start)
        for version in ["", "—", "-", "bad\nversion", String(repeating: "x", count: 129)] {
            store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: nil,
                firmwareVersion: version, at: start.addingTimeInterval(1))
        }
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: nil,
            firmwareVersion: "older", at: start.addingTimeInterval(-1))
        #expect(store.records.first?.firmwareVersion == "0.9.11")
        #expect(store.records.first?.firmwareRecordedAt == start)
    }

    private func display(id: String = "panel", percent: Int? = 73, seen: Date? = nil) -> DisplaySummary {
        DisplaySummary(id: id, name: "Desk", kind: "test_panel", iconName: "display",
            panel: PanelProfile(width: 4, height: 2, gamut: "bwry_4", orientation: "landscape"),
            freshness: .stale, lastSeenAt: seen, batteryPercent: percent)
    }

    @Test func pendingModesSurviveRestartAndAcknowledgementsAreServerScoped() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        let restored = BluetoothDisplayStore(fileURL: file)
        let pending = try #require(restored.pendingModeReports(displayIDs: ["panel"], serverID: "home").first)
        #expect(pending.observation.mode == .bluetooth)
        #expect(pending.observation.observedAt == start)
        restored.markModeReported(pending, serverID: "home")
        let reported = BluetoothDisplayStore(fileURL: file)
        #expect(reported.pendingModeReports(displayIDs: ["panel"], serverID: "home").isEmpty)
        #expect(reported.pendingModeReports(displayIDs: ["panel"], serverID: "other").isEmpty)
        reported.activeServerID = "other"
        reported.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        #expect(reported.pendingModeReports(displayIDs: ["panel"], serverID: "other").count == 1)
    }

    @Test func olderAcknowledgementCannotClearANewerLocalMode() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = BluetoothDisplayStore(fileURL: directory.appending(path: "records.plist"))
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        let old = try #require(store.pendingModeReports(displayIDs: ["panel"], serverID: "home").first)
        store.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: start.addingTimeInterval(1))
        store.markModeReported(old, serverID: "home")
        #expect(store.pendingModeReports(displayIDs: ["panel"], serverID: "home").first?.observation.mode == .wifi)
    }

    @Test func reportingRequiresDurableConfirmedEvidenceAndAnAssociatedDevice() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: nil, at: start)
        #expect(store.pendingModeReports(displayIDs: ["panel"], serverID: "home").isEmpty)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        #expect(store.pendingModeReports(displayIDs: ["same-name-other-id"], serverID: "home").isEmpty)
        let extensionStore = BluetoothDisplayStore(fileURL: file, isReadOnly: true)
        #expect(extensionStore.pendingModeReports(displayIDs: ["panel"], serverID: "home").isEmpty)
        let failed = BluetoothDisplayStore(fileURL: file.appending(path: "cannot-write.plist"))
        failed.activeServerID = "home"
        failed.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, at: start)
        #expect(failed.storageError != nil)
        #expect(failed.pendingModeReports(displayIDs: ["panel"], serverID: "home").isEmpty)
    }

    @Test func unifiedShareListReusesBluetoothAssociationAndNeverMatchesByName() throws {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        let id = UUID()
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, peripheralID: id)
        let device = NearbyTesseraeDevice(id: id, name: "Nearby Name", rssi: -45, mode: .photo,
            hardware: .picPak42, hardwareSuffix: "A1B2C3", sessionID: Data([1,2,3,4]))
        let targets = ShareDisplayTarget.catalog(displays: [display()], serverID: "home", records: store, nearby: [device])
        #expect(targets.count == 1)
        #expect(targets.first?.id == "panel")
        #expect(targets.first?.name == "Desk")
        #expect(targets.first?.isBluetooth == true)
        #expect(targets.first?.nearby?.id == id)
        #expect(targets.first?.isAvailable == true)
        let absent = ShareDisplayTarget.catalog(displays: [display()], serverID: "home", records: store, nearby: [])
        #expect(absent.first?.isBluetooth == true)
        #expect(absent.first?.isAvailable == false)
        let stranger = NearbyTesseraeDevice(id: UUID(), name: "Desk", rssi: -45, mode: .photo,
            hardware: .picPak42, hardwareSuffix: "A1B2C3", sessionID: Data([1,2,3,4]))
        let separate = ShareDisplayTarget.catalog(displays: [display()], serverID: "home", records: store, nearby: [stranger])
        #expect(separate.count == 2)
        #expect(separate.first?.nearby == nil)
        #expect(separate.first?.isAvailable == false)
        #expect(separate.last?.isAvailable == true)
    }

    @Test func extensionReadsInventoryWithoutOverwritingIt() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "inventory.plist")
        let app = BluetoothDisplayStore(fileURL: file)
        app.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil, peripheralID: UUID())
        let original = try Data(contentsOf: file)
        let share = BluetoothDisplayStore(fileURL: file, isReadOnly: true)
        #expect(share.records.first?.peripheralID == app.records.first?.peripheralID)
        share.observe(deviceID: "other", name: "Other", mode: .bluetooth, batteryMillivolts: nil)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func sharedReceiptsImportOnlyConfirmedPhotosAndPreserveNewerMode() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let receipts = directory.appending(path: "receipts")
        let share = BluetoothDisplayStore(fileURL: nil, receiptDirectoryURL: receipts)
        share.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900,
            firmwareVersion: "0.9.10", at: start)
        #expect(!FileManager.default.fileExists(atPath: receipts.path))
        let png = try LocalBluetoothPhotoRenderer.previewPNG(rgba: Data([20, 100, 180, 255]), width: 1, height: 1)
        share.receivedPhoto(deviceID: "panel", previewPNG: png, at: start.addingTimeInterval(1))
        let app = BluetoothDisplayStore(fileURL: directory.appending(path: "records.plist"))
        app.activeServerID = "home"
        app.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil,
            firmwareVersion: "0.9.11", firmwareRecordedAt: start.addingTimeInterval(0.5), at: start)
        app.importSharedPhotoReceipts(from: receipts)
        #expect(app.record(for: "panel", serverID: "home")?.previewPNG == png)
        #expect(app.record(for: "panel", serverID: "home")?.firmwareVersion == "0.9.11")
        #expect(try FileManager.default.contentsOfDirectory(atPath: receipts.path).isEmpty)
        share.receivedPhoto(deviceID: "panel", previewPNG: png, at: start.addingTimeInterval(2))
        app.observe(deviceID: "panel", name: "Desk", mode: .wifi, batteryMillivolts: nil, at: start.addingTimeInterval(3))
        app.importSharedPhotoReceipts(from: receipts)
        #expect(app.record(for: "panel", serverID: "home")?.mode == .wifi)
        #expect(app.record(for: "panel", serverID: "home")?.previewPNG == nil)
    }

    @Test func recordsSurviveRestartAndUnconfirmedWorkCannotReplaceTheImage() throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "records.plist")
        let store = BluetoothDisplayStore(fileURL: file)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, batteryPercent: 65, at: start)
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
        #expect(record.batteryPercent == 65)
        #expect(record.batteryPercentRecordedAt == start)
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

    @Test func latestPercentageWinsAcrossTransportsAndVoltageOnlyRepliesDoNotRefreshIt() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observeServer(displays: [display(seen: start)], previews: [:], serverID: "home", at: start)
        let bleDate = start.addingTimeInterval(20)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900,
                      batteryPercent: 65, at: bleDate)
        func value() -> DisplayBluetoothPresentation {
            // Even a non-cached server fallback cannot override the more recent BLE sample.
            store.presentation(for: display(percent: 90, seen: start.addingTimeInterval(-10)), serverID: "home")
        }
        #expect(value().batteryText == "65%")
        #expect(value().batteryDate == bleDate)
        let wifiDate = start.addingTimeInterval(40)
        store.observeServer(displays: [display(percent: 60, seen: wifiDate)], previews: [:], serverID: "home")
        #expect(value().batteryText == "60%")
        #expect(value().batteryDate == wifiDate)
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: 4200,
                      batteryPercent: 100, at: start.addingTimeInterval(10))
        #expect(store.record(for: "panel", serverID: "home")?.batteryPercent == 65)
        store.observe(deviceID: "panel", name: "Desk", mode: nil, batteryMillivolts: 3800,
                      at: start.addingTimeInterval(60))
        #expect(value().batteryText == "60%")
        #expect(value().batteryDate == wifiDate)
        #expect(value().record?.batteryPercentRecordedAt == bleDate)
        #expect(value().record?.batteryMillivolts == 3800)
    }

    @Test func pollingAnUndatedServerPercentageDoesNotMakeItNewerThanBluetooth() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observeServer(displays: [display()], previews: [:], serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900,
                      batteryPercent: 65, at: start.addingTimeInterval(20))
        store.observeServer(displays: [display()], previews: [:], serverID: "home", at: start.addingTimeInterval(40))
        let result = store.presentation(for: display(), serverID: "home")
        #expect(result.batteryText == "65%")
        #expect(result.batteryDate == start.addingTimeInterval(20))
        #expect(store.serverRecord(displayID: "panel", serverID: "home")?.batteryRecordedAt == nil)
        // First seeing an undated cache after the BLE measurement also cannot outrank it.
        store.observeServer(displays: [display(percent: 90)], previews: [:], serverID: "other", at: start.addingTimeInterval(60))
        store.link("panel", to: "panel", serverID: "other")
        #expect(store.presentation(for: display(percent: 90), serverID: "other").batteryText == "65%")
    }

    @Test func voltageOnlyFirmwareKeepsVoltageInDetailsWithoutInventingPercentage() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900, at: start)
        let result = store.presentation(for: display(percent: nil), serverID: "home")
        #expect(result.batteryText == "—")
        #expect(result.voltageText != nil)
        #expect(result.batteryDate == start)
    }

    @Test func anUndatedPercentageCannotBorrowTheVoltageMeasurementTime() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observeServer(displays: [display()], previews: [:], serverID: "home", at: start)
        store.observe(deviceID: "panel", name: "Desk", mode: .bluetooth, batteryMillivolts: 3900,
                      at: start.addingTimeInterval(20))
        let result = store.presentation(for: display(), serverID: "home")
        #expect(result.batteryText == "73%")
        #expect(result.batteryDate == nil)
        #expect(result.voltageText != nil)
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
        let target = display(id: "renamed-red-frame")
        store.observeServer(displays: [target], previews: [:], serverID: "home")
        store.observeMACMatches(["f8:5b:1b:4f:e8:44": target.id], serverID: "home")
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
        let target = display(id: "red")
        let duplicate = display(id: "duplicate")
        store.observeServer(displays: [target, duplicate], previews: [:], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.observeServer(displays: [target], previews: [:], serverID: "home")
        store.observeMACMatches(["f8:5b:1b:4f:e8:44": "red"], serverID: "home")
        #expect(store.record(for: "red", serverID: "home")?.mode == .bluetooth)
        store.link(nil, to: "red", serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.link("picpak-f85b1b4fe844", to: "different", serverID: "elsewhere")
        #expect(store.record(for: "red", serverID: "home") == nil)

        let ambiguous = BluetoothDisplayStore(fileURL: nil)
        ambiguous.observeServer(displays: [target], previews: [:], serverID: "home")
        for id in ["first", "second"] {
            ambiguous.observe(deviceID: id, name: "Frame", mode: .bluetooth, batteryMillivolts: nil,
                              hardwareMAC: "f8:5b:1b:4f:e8:44")
        }
        ambiguous.observeMACMatches(["f8:5b:1b:4f:e8:44": "red"], serverID: "home")
        #expect(ambiguous.record(for: "red", serverID: "home") == nil)
    }

    @Test func shortMACSuffixCannotAutomaticallyAssociate() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "picpak-4fe844", name: "Red", mode: .bluetooth, batteryMillivolts: nil)
        store.observeServer(displays: [display(id: "red")], previews: [:], serverID: "home")
        #expect(store.knownHardwareMACs.isEmpty)
        store.observeMACMatches(["f8:5b:1b:4f:e8:44": "red"], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
    }

    @Test func canonicalServerIDsRemainCompatibleWithNativeFirmware() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.activeServerID = "home"
        store.observe(deviceID: "native-panel", name: "Desk", mode: .bluetooth, batteryMillivolts: nil)
        store.observeServer(displays: [display(id: "native-panel")],
                            previews: [:], serverID: "home")
        #expect(store.record(for: "native-panel", serverID: "home")?.mode == .bluetooth)
        #expect(store.record(for: "native-panel", serverID: "other") == nil)
    }

    @Test func confirmedMACAssociationsOverrideConflictingLegacyLinks() {
        let store = BluetoothDisplayStore(fileURL: nil)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Red", mode: .bluetooth, batteryMillivolts: nil)
        store.observe(deviceID: "picpak-f85b1b4f0700", name: "Blue", mode: .bluetooth, batteryMillivolts: nil)
        store.link("picpak-f85b1b4fe844", to: "legacy", serverID: "home")
        #expect(store.record(for: "legacy", serverID: "home")?.id == "picpak-f85b1b4fe844")

        // Complete hardware evidence repairs a historical manual mismatch without deleting the record.
        store.observeServer(displays: [display(id: "legacy")], previews: [:], serverID: "home")
        store.observeMACMatches(["f8:5b:1b:4f:07:00": "legacy"], serverID: "home")
        #expect(store.record(for: "legacy", serverID: "home")?.id == "picpak-f85b1b4f0700")
        store.link("picpak-f85b1b4fe844", to: "legacy", serverID: "home")
        #expect(store.record(for: "legacy", serverID: "home")?.id == "picpak-f85b1b4f0700")
        #expect(store.records.count == 2)
    }

    @Test func lookupEvidenceIsScopedAndDoesNotTrustLegacyServerMACs() throws {
        let file = URL.temporaryDirectory.appending(path: UUID().uuidString + ".plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = BluetoothDisplayStore(fileURL: file)
        store.observe(deviceID: "picpak-f85b1b4fe844", name: "Red", mode: .bluetooth, batteryMillivolts: nil)
        store.observeServer(displays: [display(id: "red")], previews: [:], serverID: "home")
        store.observeMACMatches(["f8:5b:1b:00:00:01": "red"], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.observeMACMatches(["f8:5b:1b:4f:e8:44": "deleted"], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)
        store.observeMACMatches(["f8:5b:1b:4f:e8:44": "red"], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") != nil)
        #expect(store.record(for: "red", serverID: "other") == nil)
        store.observeMACMatches([:], serverID: "home")
        #expect(store.record(for: "red", serverID: "home") == nil)

        var plist = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any])
        plist["servers"] = ["home": ["red": ["hardwareMAC": "f8:5b:1b:4f:e8:44"]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: file)
        #expect(BluetoothDisplayStore(fileURL: file).record(for: "red", serverID: "home") == nil)
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
