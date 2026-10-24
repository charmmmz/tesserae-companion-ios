import CryptoKit
import Foundation

enum BLESetupProtocol {
    static let serviceUUID = "7A5E0001-7B6D-4F8B-9C2E-1D0A5A110001"
    static let photoServiceUUID = "7A5E0007-7B6D-4F8B-9C2E-1D0A5A110001"
    static let unifiedPhotoServiceUUID = "7A5E0008-7B6D-4F8B-9C2E-1D0A5A110001"
    static let photoDataUUID = "7A5E0006-7B6D-4F8B-9C2E-1D0A5A110001"
    static let infoUUID = "7A5E0002-7B6D-4F8B-9C2E-1D0A5A110001"
    static let qrControlUUID = "7A5E0003-7B6D-4F8B-9C2E-1D0A5A110001"
    static let passkeyControlUUID = "7A5E0004-7B6D-4F8B-9C2E-1D0A5A110001"
    static let eventsUUID = "7A5E0005-7B6D-4F8B-9C2E-1D0A5A110001"

    static let protocolMajor: UInt8 = 2
    static let connectionNonceBytes = 16
    static let nativeFrame: UInt8 = 0xA0
    static let qrFrame: UInt8 = 0xA1
    static let maximumMessageBytes = 512
}

struct BLESetupConfiguration {
    let ssid: String
    let password: String
    let serverURL: URL?
    let pairingCode: String

    var stageCommand: [String: Any] {
        var command: [String: Any] = [
            "op": "stage", "ssid": ssid, "password": password,
            "server_url": serverURL?.absoluteString ?? "",
            "pairing_code": pairingCode,
        ]
        // Preserve intent belongs to the request, not to maintenance mode:
        // maintenance can either repair Wi-Fi or explicitly replace a server.
        if serverURL == nil { command["preserve_server"] = true }
        return command
    }

    static func serverURL(from address: String) -> URL? {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        guard value.utf8.count < 160,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true
        else { return nil }
        components.scheme = scheme
        guard let url = components.url, url.absoluteString.utf8.count < 160 else { return nil }
        return url
    }

    static func isValidPairingCode(_ code: String) -> Bool {
        code.utf8.count == 6 && code.utf8.allSatisfy { (48...57).contains($0) }
    }
}

enum BLESetupProtocolError: Error, LocalizedError {
    case invalidQRCode
    case unsupportedVersion
    case invalidFrame
    case replayedFrame
    case authenticationFailed
    case invalidChunk
    case messageTooLarge
    case unexpectedDevice

    var errorDescription: String? {
        switch self {
        case .invalidQRCode: "That is not a Tesserae setup code."
        case .unsupportedVersion: "This display uses an unsupported setup protocol."
        case .invalidFrame: "The display sent an invalid Bluetooth message."
        case .replayedFrame: "A repeated Bluetooth message was rejected."
        case .authenticationFailed: "The setup code could not authenticate this display."
        case .invalidChunk: "The Bluetooth message arrived out of order."
        case .messageTooLarge: "The Bluetooth message is too large."
        case .unexpectedDevice: "The scanned code belongs to a different display."
        }
    }
}

struct BLESetupQRCode: Equatable, Sendable {
    let deviceID: String
    let sessionID: Data
    let secret: Data

    init(deviceID: String, sessionID: Data, secret: Data) {
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.secret = secret
    }

    init(string: String) throws {
        guard
            let components = URLComponents(string: string),
            components.scheme?.lowercased() == "tesserae",
            components.host?.lowercased() == "setup",
            let version = components.queryValue(named: "v"),
            let deviceID = components.queryValue(named: "id"),
            !deviceID.isEmpty,
            let sessionHex = components.queryValue(named: "sid"),
            let sessionID = Data(hex: sessionHex),
            sessionID.count == 4,
            let rawKey = components.queryValue(named: "key"),
            let secret = Data(base64URLEncoded: rawKey),
            secret.count == 32
        else {
            throw BLESetupProtocolError.invalidQRCode
        }
        guard version == String(BLESetupProtocol.protocolMajor) else {
            throw BLESetupProtocolError.unsupportedVersion
        }
        self.deviceID = deviceID
        self.sessionID = sessionID
        self.secret = secret
    }
}

struct BLESetupAdvertisement: Equatable, Sendable {
    let mode: NearbyDeviceMode
    let hardware: BLESetupHardware
    let hardwareSuffix: String
    let sessionID: Data

    init(
        mode: NearbyDeviceMode,
        hardware: BLESetupHardware,
        hardwareSuffix: String,
        sessionID: Data
    ) {
        self.mode = mode
        self.hardware = hardware
        self.hardwareSuffix = hardwareSuffix
        self.sessionID = sessionID
    }

    init?(serviceData: Data) {
        var payload = serviceData
        // CoreBluetooth normally removes the 128-bit service UUID. Accept the
        // raw AD payload as well so fixture captures remain useful.
        if payload.count == 26 {
            payload = Data(payload.dropFirst(16))
        }
        guard
            payload.count == 10,
            payload[0] == BLESetupProtocol.protocolMajor
        else { return nil }
        guard payload[1] <= 4 else { return nil }
        mode = payload[1] == 4 ? .photo : (payload[1] & 0x02 != 0 ? .maintenance : .setup)
        self.hardware = BLESetupHardware(rawValue: payload[2])
        hardwareSuffix = payload[3..<6]
            .map { String(format: "%02X", $0) }
            .joined()
        sessionID = Data(payload[6..<10])
    }
}

/// Broadcast codes are hints. Codes 8 and 9 have conflicting legacy reservations;
/// connected device info confirms identity. PicPak requires its assigned code 20.
enum BLESetupHardware: Equatable, Sendable {
    case seeedReTerminalE1001, seeedReTerminalE1002, seeedReTerminalE1003, seeedReTerminalE1004
    case seeedEE02, seeedEE03, seeedEE0475, seeedEE0473E6, seeedEE05, seeedSticky
    case seeedXIAO75, waveshare133E6, wavesharePhotoPainter73, picPak42
    case paperMono, goodDisplay133, inkplate13
    case unknown(UInt8)

    init(rawValue: UInt8) {
        switch rawValue {
        case 1: self = .seeedReTerminalE1001
        case 2: self = .seeedReTerminalE1002
        case 3: self = .seeedReTerminalE1003
        case 4: self = .seeedReTerminalE1004
        case 5: self = .seeedEE02
        case 6: self = .seeedEE0475
        case 7: self = .seeedEE0473E6
        case 20: self = .picPak42
        default: self = .unknown(rawValue)
        }
    }

    var rawValue: UInt8 {
        switch self {
        case .seeedReTerminalE1001: 1
        case .seeedReTerminalE1002: 2
        case .seeedReTerminalE1003: 3
        case .seeedReTerminalE1004: 4
        case .seeedEE02: 5
        case .seeedEE0475: 6
        case .seeedEE0473E6: 7
        case .seeedXIAO75, .seeedSticky: 8
        case .waveshare133E6, .seeedEE05: 9
        case .wavesharePhotoPainter73: 10
        case .seeedEE03: 11
        case .paperMono: 12
        case .goodDisplay133: 18
        case .inkplate13: 19
        case .picPak42: 20
        case .unknown(let code): code
        }
    }

    var catalogKind: String {
        switch self {
        case .seeedReTerminalE1001: "seeed_reterminal_e1001"
        case .seeedReTerminalE1002: "seeed_reterminal_e1002"
        case .seeedReTerminalE1003: "seeed_reterminal_e1003"
        case .seeedReTerminalE1004: "seeed_reterminal_e1004"
        case .seeedEE02: "seeed_ee02"
        case .seeedEE03: "seeed_ee03"
        case .seeedEE0475: "seeed_ee04_75"
        case .seeedEE0473E6: "seeed_ee04_73e6"
        case .seeedEE05: "seeed_ee05_213_bwry"
        case .seeedSticky: "seeed_reterminal_sticky"
        case .seeedXIAO75: "seeed_xiao_75"
        case .waveshare133E6: "waveshare_133e6"
        case .wavesharePhotoPainter73: "waveshare_photopainter_73"
        case .picPak42: "picpak_4_2"
        case .paperMono: "m5stack_papermono"
        case .goodDisplay133: "gooddisplay_esp32_133c02"
        case .inkplate13: "soldered_inkplate_13spectra"
        case .unknown: "unknown"
        }
    }

    static func resolve(code: UInt8, model: String) -> Self {
        let normalized = model.lowercased().filter { $0.isLetter || $0.isNumber }
        let candidates: [Self] = [.seeedReTerminalE1001, .seeedReTerminalE1002,
            .seeedReTerminalE1003, .seeedReTerminalE1004, .seeedEE02, .seeedEE03,
            .seeedEE0475, .seeedEE0473E6, .seeedEE05, .seeedSticky, .seeedXIAO75,
            .waveshare133E6, .wavesharePhotoPainter73, .picPak42, .paperMono,
            .goodDisplay133, .inkplate13]
        return candidates.first { candidate in
            guard candidate.rawValue == code else { return false }
            let catalog = candidate.catalogKind.filter { $0.isLetter || $0.isNumber }
            let aliases: [String]
            switch candidate {
            case .seeedReTerminalE1001: aliases = ["reterminale1001"]
            case .seeedReTerminalE1002: aliases = ["reterminale1002"]
            case .seeedReTerminalE1003: aliases = ["reterminale1003"]
            case .seeedReTerminalE1004: aliases = ["reterminale1004"]
            case .seeedSticky: aliases = ["reterminalsticky"]
            case .seeedEE0475: aliases = ["seeedee0475"]
            case .seeedEE0473E6: aliases = ["seeedee0473e6"]
            case .paperMono: aliases = ["papermono"]
            case .goodDisplay133: aliases = ["gooddisplayesp32133c02"]
            case .inkplate13: aliases = ["inkplate13spectra"]
            default: aliases = []
            }
            return normalized == catalog || aliases.contains(normalized)
        } ?? .unknown(code)
    }
}
enum BLERefreshSpeed: String, CaseIterable, Equatable, Sendable {
    case fiveSeconds = "5s"
    case tenSeconds = "10s"
    case native = "native"

    var displayName: String {
        switch self {
        case .fiveSeconds: String(localized: "5 s")
        case .tenSeconds: String(localized: "10 s")
        case .native: String(localized: "Native")
        }
    }
}

/// Tracks the device-confirmed setting separately from an in-flight write.
/// After a timeout, read back before allowing another write: protocol v2 does
/// not include request IDs, so a late acknowledgement must not confirm a retry.
struct NearbyRefreshSpeedSetting: Equatable, Sendable {
    private(set) var confirmedValue: BLERefreshSpeed?
    private(set) var pendingValue: BLERefreshSpeed?
    private(set) var needsReadback = false
    private(set) var errorMessage: String?

    var isSaving: Bool { pendingValue != nil }

    mutating func receiveDiagnostics(_ value: BLERefreshSpeed?, hardware: BLESetupHardware?) {
        guard !isSaving else { return }
        confirmedValue = hardware == .picPak42 ? value : nil
        if needsReadback { errorMessage = nil }
        needsReadback = false
    }

    @discardableResult
    mutating func beginSaving(_ value: BLERefreshSpeed) -> Bool {
        guard let confirmedValue, value != confirmedValue,
              !isSaving, !needsReadback else { return false }
        pendingValue = value
        errorMessage = nil
        return true
    }

    @discardableResult
    mutating func acknowledge(_ rawValue: String?) -> Bool {
        guard let pendingValue,
              let rawValue,
              let value = BLERefreshSpeed(rawValue: rawValue),
              value == pendingValue else { return false }
        confirmedValue = value
        self.pendingValue = nil
        errorMessage = nil
        return true
    }

    mutating func fail(_ message: String, needsReadback: Bool = false) {
        pendingValue = nil
        errorMessage = message
        self.needsReadback = needsReadback
    }

    mutating func reset() {
        self = Self()
    }
}

struct BLESetupDeviceInfo: Decodable, Equatable, Sendable {
    let `protocol`: Int
    let id: String
    let sid: String
    let connectionNonce: String
    let hardware: UInt8
    let model: String
    let firmware: String
    let mode: String
    var photo: Int? = nil
    var family: String? = nil
    var kind: String? = nil

    var resolvedHardware: BLESetupHardware {
        BLESetupHardware.resolve(code: hardware, model: model)
    }

    private enum CodingKeys: String, CodingKey {
        case `protocol`, id, sid, hardware, model, firmware, mode, photo, family, kind
        case connectionNonce = "connection_nonce"
    }

    func validate(qrCode: BLESetupQRCode) throws -> Data {
        guard `protocol` == Int(BLESetupProtocol.protocolMajor) else {
            throw BLESetupProtocolError.unsupportedVersion
        }
        guard id == qrCode.deviceID,
              sid.lowercased() == qrCode.sessionID.hexString else {
            throw BLESetupProtocolError.unexpectedDevice
        }
        guard
            let nonce = Data(hex: connectionNonce),
            nonce.count == BLESetupProtocol.connectionNonceBytes
        else { throw BLESetupProtocolError.invalidFrame }
        return nonce
    }
}

struct BLESetupCrypto {
    enum Direction: UInt8 {
        case appToDevice = 0
        case deviceToApp = 1
    }

    private let key: SymmetricKey
    private let sessionID: Data
    private var transmitCounter: UInt32 = 0
    private var receiveCounter: UInt32 = 0

    init(qrCode: BLESetupQRCode, connectionNonce: Data) throws {
        guard connectionNonce.count == BLESetupProtocol.connectionNonceBytes else {
            throw BLESetupProtocolError.invalidFrame
        }
        var salt = qrCode.sessionID
        salt.append(connectionNonce)
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: qrCode.secret),
            salt: salt,
            info: Data("tesserae-ble-connection-key-v2".utf8),
            outputByteCount: 32
        )
        sessionID = qrCode.sessionID
    }

    mutating func seal(_ plaintext: Data, direction: Direction) throws -> Data {
        guard plaintext.count <= BLESetupProtocol.maximumMessageBytes else {
            throw BLESetupProtocolError.messageTooLarge
        }
        transmitCounter &+= 1
        guard transmitCounter != 0 else { throw BLESetupProtocolError.invalidFrame }

        var header = Data([BLESetupProtocol.qrFrame])
        header.append(transmitCounter.bigEndianData)
        let nonce = try AES.GCM.Nonce(data: nonceData(
            direction: direction,
            counter: transmitCounter
        ))
        let sealed = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: header
        )
        return header + sealed.ciphertext + sealed.tag
    }

    mutating func open(_ frame: Data, direction: Direction) throws -> Data {
        guard frame.count >= 21, frame.first == BLESetupProtocol.qrFrame else {
            throw BLESetupProtocolError.invalidFrame
        }
        let counter = frame[1..<5].uint32BigEndian
        guard counter > receiveCounter else {
            throw BLESetupProtocolError.replayedFrame
        }
        let header = frame.prefix(5)
        let ciphertext = frame.dropFirst(5).dropLast(16)
        let tag = frame.suffix(16)
        do {
            let nonce = try AES.GCM.Nonce(data: nonceData(
                direction: direction,
                counter: counter
            ))
            let box = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            let plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: header
            )
            receiveCounter = counter
            return plaintext
        } catch {
            throw BLESetupProtocolError.authenticationFailed
        }
    }

    private func nonceData(direction: Direction, counter: UInt32) -> Data {
        var nonce = sessionID
        nonce.append(direction.rawValue)
        nonce.append(contentsOf: [0, 0, 0])
        nonce.append(counter.bigEndianData)
        return nonce
    }
}

struct BLESetupReassembler {
    private var messageID: UInt16?
    private var nextIndex: UInt8 = 0
    private var chunkCount: UInt8 = 0
    private var bytes = Data()

    mutating func push(_ chunk: Data) throws -> Data? {
        guard chunk.count >= 4 else { throw BLESetupProtocolError.invalidChunk }
        let incomingID = UInt16(chunk[0]) << 8 | UInt16(chunk[1])
        let index = chunk[2]
        let count = chunk[3]
        guard count > 0, index < count else {
            reset()
            throw BLESetupProtocolError.invalidChunk
        }
        if index == 0 {
            reset()
            messageID = incomingID
            chunkCount = count
        }
        guard messageID == incomingID, chunkCount == count, nextIndex == index else {
            reset()
            throw BLESetupProtocolError.invalidChunk
        }
        bytes.append(chunk.dropFirst(4))
        guard bytes.count <= BLESetupProtocol.maximumMessageBytes else {
            reset()
            throw BLESetupProtocolError.messageTooLarge
        }
        nextIndex &+= 1
        guard nextIndex == chunkCount else { return nil }
        let result = bytes
        reset()
        return result
    }

    mutating func reset() {
        messageID = nil
        nextIndex = 0
        chunkCount = 0
        bytes.removeAll(keepingCapacity: true)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }

    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private extension URLComponents {
    func queryValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension UInt32 {
    var bigEndianData: Data {
        Data([
            UInt8(truncatingIfNeeded: self >> 24),
            UInt8(truncatingIfNeeded: self >> 16),
            UInt8(truncatingIfNeeded: self >> 8),
            UInt8(truncatingIfNeeded: self),
        ])
    }
}

private extension Data.SubSequence {
    var uint32BigEndian: UInt32 {
        reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
