import Foundation
import CryptoKit
import Security
import TesseraeKit

enum BLEScreenMode: String, CaseIterable, Sendable {
    case wifi, bluetooth
    var title: String {
        switch self {
        case .wifi: String(localized: "Automatic (Wi-Fi)")
        case .bluetooth: String(localized: "Manual (Bluetooth)")
        }
    }
}

enum BLEPhotoState: Equatable {
    case idle, sending, received
}

/// Optional status from authenticated photo_info. Older firmware can omit it.
struct BLEPhotoDeviceStatus: Equatable {
    let batteryMillivolts: Int?
    let lowBattery: Bool?
    let refreshSpeed: BLERefreshSpeed?
    let screenMode: BLEScreenMode?

    init(event: [String: Any]) {
        if let mv = event["battery_mv"] as? NSNumber,
           CFGetTypeID(mv) != CFBooleanGetTypeID(),
           (2500...5000).contains(mv.doubleValue),
           mv.doubleValue == Double(mv.intValue) {
            batteryMillivolts = mv.intValue
        } else {
            batteryMillivolts = nil
        }
        if batteryMillivolts != nil, let low = event["low_battery"] as? NSNumber,
           CFGetTypeID(low) == CFBooleanGetTypeID() {
            lowBattery = low.boolValue
        } else {
            lowBattery = nil
        }
        refreshSpeed = (event["refresh_speed"] as? String).flatMap(BLERefreshSpeed.init)
        screenMode = (event["screen_mode"] as? String).flatMap(BLEScreenMode.init)
    }

    var batteryText: String? {
        batteryMillivolts.map {
            (Double($0) / 1000).formatted(.number.precision(.fractionLength(2))) + " V"
        }
    }
}

/// One bounded upload with cumulative acknowledgements. Original Photo v2
/// firmware and PicPak keep a one-packet window unless explicitly negotiated.
struct BLEPhotoTransfer {
    static let byteCount = 30_000
    static let chunkBytes = 192
    static let format = "picpak-bwry2-bottom-up"
    let id: UInt32
    let data: Data
    let capabilities: BluetoothPhotoCapabilities?
    private(set) var offset = 0
    private(set) var expectedOffset = 0
    private(set) var isAwaitingBegin = true

    init(data: Data, id: UInt32, capabilities: BluetoothPhotoCapabilities? = nil) throws {
        try capabilities?.validate()
        guard data.count == (capabilities?.bytes ?? Self.byteCount), id != 0 else {
            throw BLESetupProtocolError.invalidFrame
        }
        self.data = data
        self.id = id
        self.capabilities = capabilities
    }
    var digest: String { Data(SHA256.hash(data: data)).hexString }
    var windowSize: Int { capabilities?.maxWindow ?? 1 }
    private var packetBytes: Int { capabilities?.chunkBytes ?? Self.chunkBytes }
    var outstandingPacketCount: Int { (expectedOffset - offset + packetBytes - 1) / packetBytes }
    var waitingForReceipt: Bool { !isAwaitingBegin && offset == data.count }

    mutating func acknowledge(_ value: Int) throws -> Bool {
        guard value >= 0, value <= data.count else { throw BLESetupProtocolError.invalidFrame }
        if isAwaitingBegin {
            guard value == 0 else { throw BLESetupProtocolError.invalidFrame }
            isAwaitingBegin = false
            return true
        }
        guard value <= expectedOffset, value == data.count || value % packetBytes == 0 else {
            throw BLESetupProtocolError.invalidFrame
        }
        if value <= offset { return false }
        offset = value
        return true
    }

    /// Returns only new packets that fit the free window; a full window waits
    /// for an ACK even when every frame byte has already been sent.
    mutating func nextPackets() -> [Data] {
        var packets: [Data] = []
        while let packet = nextPacket() { packets.append(packet) }
        return packets
    }

    mutating func nextPacket() -> Data? {
        guard !isAwaitingBegin, !waitingForReceipt, expectedOffset < data.count,
              outstandingPacketCount < windowSize else { return nil }
        let start = expectedOffset
        let end = min(start + packetBytes, data.count)
        expectedOffset = end
        return packet(at: start)
    }

    /// Retries preserve the logical packet bytes. The caller must seal each
    /// returned packet again with a fresh authenticated-transport nonce.
    func retryPackets() -> [Data] {
        stride(from: offset, to: expectedOffset, by: packetBytes).map { packet(at: $0) }
    }

    private func packet(at start: Int) -> Data {
        let end = min(start + packetBytes, data.count)
        var packet = Self.bigEndian(id) + Self.bigEndian(UInt32(start))
        packet.append(data[start..<end])
        return packet
    }
    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
              UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
}

/// Device authorization is local to this installation, never synced to a server.
enum BLEPhotoKeyStore {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.charmmmz.tesseraecompanion.ble-photo",
         kSecAttrAccount as String: id]
    }
    static func read(_ id: String) -> Data? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return data
    }
    static func save(_ data: Data, for id: String) throws {
        guard data.count == 32 else { throw BLESetupProtocolError.invalidFrame }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(id).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}
