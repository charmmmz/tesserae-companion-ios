import Foundation

public enum DeviceHardwareIdentity {
    /// A complete unicast Wi-Fi MAC. Short advertised suffixes are not identities.
    public static func normalizedMAC(_ value: String?) -> String? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        let compact: String
        if raw.count == 12 {
            compact = raw.lowercased()
        } else {
            let separator: Character = raw.contains(":") ? ":" : "-"
            let octets = raw.split(separator: separator, omittingEmptySubsequences: false)
            guard octets.count == 6, octets.allSatisfy({ $0.utf8.count == 2 }) else { return nil }
            compact = octets.joined().lowercased()
        }
        guard compact.utf8.count == 12,
              compact.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              compact != "000000000000", compact != "ffffffffffff",
              let first = UInt8(compact.prefix(2), radix: 16), first & 1 == 0 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { offset in
            String(compact.dropFirst(offset).prefix(2))
        }.joined(separator: ":")
    }

    /// PicPak firmware has always used the full Wi-Fi MAC in its authenticated BLE identity.
    public static func picPakMAC(bluetoothID: String) -> String? {
        guard bluetoothID.hasPrefix("picpak-") else { return nil }
        return normalizedMAC(String(bluetoothID.dropFirst(7)))
    }
}
