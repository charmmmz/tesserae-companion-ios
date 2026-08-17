import CryptoKit
import Foundation

enum BLESetupProtocol {
    static let serviceUUID = "7A5E0001-7B6D-4F8B-9C2E-1D0A5A110001"
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
            payload[0] == BLESetupProtocol.protocolMajor,
            let hardware = BLESetupHardware(rawValue: payload[2])
        else { return nil }
        mode = payload[1] & 0x02 != 0 ? .maintenance : .setup
        self.hardware = hardware
        hardwareSuffix = payload[3..<6]
            .map { String(format: "%02X", $0) }
            .joined()
        sessionID = Data(payload[6..<10])
    }
}

enum BLESetupHardware: UInt8, Equatable, Sendable {
    case seeedReTerminalE1001 = 1
    case seeedReTerminalE1002 = 2
    case seeedReTerminalE1003 = 3
    case seeedReTerminalE1004 = 4
    case seeedEE02 = 5
    case seeedEE0475 = 6
    case seeedEE0473E6 = 7
    case seeedXIAO75 = 8
    case waveshare133E6 = 9
    case wavesharePhotoPainter73 = 10

    var catalogKind: String {
        switch self {
        case .seeedReTerminalE1001: "seeed_reterminal_e1001"
        case .seeedReTerminalE1002: "seeed_reterminal_e1002"
        case .seeedReTerminalE1003: "seeed_reterminal_e1003"
        case .seeedReTerminalE1004: "seeed_reterminal_e1004"
        case .seeedEE02: "seeed_ee02"
        case .seeedEE0475: "seeed_ee04_75"
        case .seeedEE0473E6: "seeed_ee04_73e6"
        case .seeedXIAO75: "seeed_xiao_75"
        case .waveshare133E6: "waveshare_133e6"
        case .wavesharePhotoPainter73: "waveshare_photopainter_73"
        }
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

    private enum CodingKeys: String, CodingKey {
        case `protocol`, id, sid, hardware, model, firmware, mode
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
