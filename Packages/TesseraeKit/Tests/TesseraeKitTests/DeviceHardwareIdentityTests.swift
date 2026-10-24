import Foundation
import Testing
@testable import TesseraeKit

struct DeviceHardwareIdentityTests {
    @Test(arguments: ["F8:5B:1B:4F:E8:44", "f8-5b-1b-4f-e8-44", "f85b1b4fe844"])
    func normalizesCompleteAddresses(_ value: String) {
        #expect(DeviceHardwareIdentity.normalizedMAC(value) == "f8:5b:1b:4f:e8:44")
    }

    @Test(arguments: ["4fe844", "00:00:00:00:00:00", "ff:ff:ff:ff:ff:ff",
                      "01:02:03:04:05:06", "f8:5b:1b:4f:e8:zz", "f8:5b:1b:4f:e8:44:55"])
    func rejectsIncompleteOrInvalidAddresses(_ value: String) {
        #expect(DeviceHardwareIdentity.normalizedMAC(value) == nil)
    }

    @Test func knownBLEIdentityUsesAllSixMACOctets() {
        #expect(DeviceHardwareIdentity.picPakMAC(bluetoothID: "picpak-f85b1b4fe844") == "f8:5b:1b:4f:e8:44")
        #expect(DeviceHardwareIdentity.picPakMAC(bluetoothID: "picpak-4fe844") == nil)
        #expect(DeviceHardwareIdentity.picPakMAC(bluetoothID: "other-f85b1b4fe844") == nil)
    }

    @Test func deviceDecodingSupportsMACAndOlderServers() throws {
        let display = DisplaySummary(id: "red", name: "Red", kind: "picpak_client", iconName: "display",
            panel: PanelProfile(width: 400, height: 300, gamut: "bwry_4", orientation: "landscape"), freshness: .stale)
        let old = try JSONEncoder().encode(display)
        #expect(try JSONDecoder().decode(DisplaySummary.self, from: old).mac == nil)
        var json = try #require(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json["mac"] = "f8:5b:1b:4f:e8:44"
        let new = try JSONSerialization.data(withJSONObject: json)
        #expect(try JSONDecoder().decode(DisplaySummary.self, from: new).mac == "f8:5b:1b:4f:e8:44")
    }
}
