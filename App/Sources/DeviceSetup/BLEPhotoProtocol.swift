import Foundation
import CryptoKit
import Security
import TesseraeKit

enum BLEScreenMode: String, Codable, CaseIterable, Sendable {
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

/// Battery values are device estimates; never infer charge from a generic curve here.
struct BLEBatteryReading: Equatable, Sendable {
    let millivolts: Int?
    let percent: Int?

    init(event: [String: Any]) {
        millivolts = Self.integer(event["battery_mv"], in: 2500...5000)
        percent = Self.integer(event["battery_pct"], in: 0...100)
    }

    private static func integer(_ value: Any?, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              range.contains(number.intValue),
              number.doubleValue == Double(number.intValue) else { return nil }
        return number.intValue
    }
}

/// Optional status from authenticated photo_info. Older firmware can omit it.
struct BLEPhotoDeviceStatus: Equatable {
    let batteryMillivolts: Int?
    let batteryPercent: Int?
    let lowBattery: Bool?
    let refreshSpeed: BLERefreshSpeed?
    let screenMode: BLEScreenMode?

    init(event: [String: Any]) {
        let battery = BLEBatteryReading(event: event)
        batteryMillivolts = battery.millivolts
        batteryPercent = battery.percent
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
        batteryPercent.map { "\($0)%" }
    }

    var voltageText: String? {
        batteryMillivolts.map {
            (Double($0) / 1000).formatted(.number.precision(.fractionLength(2))) + " V"
        }
    }
}

/// Optional transport fields shared by authenticated Photo v1/v2 replies.
/// chunk_bytes remains a receiver ceiling, independent of the connection MTU.
struct BLEPhotoTransportCapabilities: Decodable {
    let chunkBytes: Int
    let maxWindow: Int?
    let writeWithoutResponse: Bool?

    enum CodingKeys: String, CodingKey {
        case chunkBytes = "chunk_bytes", maxWindow = "max_window"
        case writeWithoutResponse = "write_without_response"
    }

    func negotiate(maximumWriteWithoutResponse: Int,
                   characteristicAllowsWriteWithoutResponse: Bool) throws -> BLEPhotoTransport {
        guard (1...384).contains(chunkBytes), (1...4).contains(maxWindow ?? 1) else {
            throw BLESetupProtocolError.invalidFrame
        }
        // 8-byte photo header + 4-byte fragment header + 21-byte AES-GCM envelope.
        // Unlike the with-response limit (which can allow ATT long writes), this
        // limit describes data that fits a single ordinary ATT write.
        let singleWritePixels = maximumWriteWithoutResponse > 33 ? maximumWriteWithoutResponse - 33 : 0
        return BLEPhotoTransport(
            packetBytes: singleWritePixels > 0 ? min(chunkBytes, singleWritePixels) : chunkBytes,
            windowSize: maxWindow ?? 1,
            usesWriteWithoutResponse: writeWithoutResponse == true
                && characteristicAllowsWriteWithoutResponse && singleWritePixels > 0
        )
    }
}

struct BLEPhotoTransport: Equatable {
    let packetBytes: Int
    let windowSize: Int
    let usesWriteWithoutResponse: Bool
}

/// A single ordered queue preserves encrypted counters across control and photo
/// characteristics. WWR consumes platform credit; response writes remain barriers.
struct BLEWriteQueue<Destination> {
    struct Frame {
        let data: Data
        let destination: Destination
        let withoutResponse: Bool
    }
    private var pending: [Frame] = []
    private(set) var inFlight: Frame?
    var isDrained: Bool { pending.isEmpty && inFlight == nil }

    mutating func append(_ data: Data, to destination: Destination, withoutResponse: Bool) {
        pending.append(Frame(data: data, destination: destination, withoutResponse: withoutResponse))
    }

    mutating func next(canSendWithoutResponse: Bool) -> Frame? {
        guard inFlight == nil, let next = pending.first,
              !next.withoutResponse || canSendWithoutResponse else { return nil }
        pending.removeFirst()
        if !next.withoutResponse { inFlight = next }
        return next
    }

    mutating func completeResponse() { inFlight = nil }
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
    let transport: BLEPhotoTransport
    private(set) var offset = 0
    private(set) var expectedOffset = 0
    private(set) var isAwaitingBegin = true

    init(data: Data, id: UInt32, capabilities: BluetoothPhotoCapabilities? = nil,
         transport: BLEPhotoTransport? = nil) throws {
        try capabilities?.validate()
        let transport = transport ?? BLEPhotoTransport(
            packetBytes: capabilities?.chunkBytes ?? Self.chunkBytes,
            windowSize: capabilities?.maxWindow ?? 1, usesWriteWithoutResponse: false)
        guard data.count == (capabilities?.bytes ?? Self.byteCount), id != 0 else {
            throw BLESetupProtocolError.invalidFrame
        }
        guard (1...(capabilities?.chunkBytes ?? Self.chunkBytes)).contains(transport.packetBytes),
              (1...(capabilities?.maxWindow ?? (capabilities == nil ? 4 : 1))).contains(transport.windowSize)
        else { throw BLESetupProtocolError.invalidFrame }
        self.data = data
        self.id = id
        self.capabilities = capabilities
        self.transport = transport
    }
    var digest: String { Data(SHA256.hash(data: data)).hexString }
    var windowSize: Int { transport.windowSize }
    var packetBytes: Int { transport.packetBytes }
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

    /// Only called after photo_status has drained earlier device commands. A
    /// cumulative ACK alone is not a barrier and must never rewind this cursor.
    mutating func resynchronize(_ value: Int) throws {
        guard !isAwaitingBegin, value >= offset, value <= expectedOffset,
              value == data.count || value % packetBytes == 0 else {
            throw BLESetupProtocolError.invalidFrame
        }
        offset = value
        expectedOffset = value
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
