import XCTest
@testable import Tesserae_Companion

final class BLESetupProtocolTests: XCTestCase {
    func testQRCodeParsesEphemeralIdentityAndSecret() throws {
        let key = Data(0..<32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = try BLESetupQRCode(
            string: "tesserae://setup?v=1&id=device-123&sid=12345678&key=\(key)"
        )

        XCTAssertEqual(code.deviceID, "device-123")
        XCTAssertEqual(code.sessionID, Data([0x12, 0x34, 0x56, 0x78]))
        XCTAssertEqual(code.secret, Data(0..<32))
    }

    func testQRCodeRejectsWrongSchemeAndKeyLength() {
        XCTAssertThrowsError(try BLESetupQRCode(
            string: "https://example.com/setup?v=1&id=x&sid=12345678&key=AA"
        ))
        XCTAssertThrowsError(try BLESetupQRCode(
            string: "tesserae://setup?v=1&id=x&sid=12345678&key=AA"
        ))
    }

    func testAdvertisementDecodesSetupModeAndHardwareSuffix() throws {
        XCTAssertEqual(
            BLESetupAdvertisement(
                serviceData: Data([1, 0x01, 0xA1, 0xB2, 0xC3])
            ),
            BLESetupAdvertisement(
                mode: .setup,
                hardwareSuffix: "A1B2C3"
            )
        )
        XCTAssertEqual(
            BLESetupAdvertisement(
                serviceData: Data(repeating: 0, count: 16) + Data([
                    1, 0x02, 0x11, 0x22, 0x33, 0x12, 0x34, 0x56, 0x78,
                ])
            ),
            BLESetupAdvertisement(
                mode: .maintenance,
                hardwareSuffix: "112233",
                sessionID: Data([0x12, 0x34, 0x56, 0x78])
            )
        )
        XCTAssertNil(BLESetupAdvertisement(
            serviceData: Data([2, 0x01, 0, 0, 1])
        ))
    }

    func testQRFrameRoundTripAndReplayProtection() throws {
        let code = try makeCode()
        var sender = BLESetupCrypto(qrCode: code)
        var receiver = BLESetupCrypto(qrCode: code)
        let message = Data(#"{"op":"scan"}"#.utf8)

        let frame = try sender.seal(message, direction: .appToDevice)
        XCTAssertEqual(
            try receiver.open(frame, direction: .appToDevice),
            message
        )
        XCTAssertThrowsError(try receiver.open(frame, direction: .appToDevice))
    }

    func testQRFrameMatchesFirmwareProtocolVector() throws {
        let key = Data((0..<32).map { UInt8($0 * 7 + 3) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = try BLESetupQRCode(
            string: "tesserae://setup?v=1&id=vector&sid=12345678&key=\(key)"
        )
        var crypto = BLESetupCrypto(qrCode: code)

        let frame = try crypto.seal(
            Data(#"{"op":"scan"}"#.utf8),
            direction: .appToDevice
        )

        XCTAssertEqual(
            frame.hexString,
            "a100000001ff376d6cad13ae441261d0a6144f5191fb19ada9bd692880497a881b96"
        )
    }

    func testQRFrameAuthenticatesDirection() throws {
        let code = try makeCode()
        var sender = BLESetupCrypto(qrCode: code)
        var receiver = BLESetupCrypto(qrCode: code)
        let frame = try sender.seal(Data("hello".utf8), direction: .appToDevice)

        XCTAssertThrowsError(try receiver.open(frame, direction: .deviceToApp))
    }

    func testChunkReassemblyRejectsOutOfOrderInput() throws {
        var reassembler = BLESetupReassembler()
        XCTAssertNil(try reassembler.push(Data([0, 7, 0, 2]) + Data("abc".utf8)))
        XCTAssertEqual(
            try reassembler.push(Data([0, 7, 1, 2]) + Data("def".utf8)),
            Data("abcdef".utf8)
        )

        XCTAssertThrowsError(
            try reassembler.push(Data([0, 8, 1, 2]) + Data("bad".utf8))
        )
    }

    private func makeCode() throws -> BLESetupQRCode {
        let key = Data((0..<32).map(UInt8.init)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try BLESetupQRCode(
            string: "tesserae://setup?v=1&id=device-123&sid=12345678&key=\(key)"
        )
    }
}
