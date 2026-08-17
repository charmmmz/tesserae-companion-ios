import XCTest
@testable import Tesserae_Companion

final class BLESetupProtocolTests: XCTestCase {
    func testQRCodeParsesEphemeralIdentityAndSecret() throws {
        let key = Data(0..<32).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = try BLESetupQRCode(
            string: "tesserae://setup?v=2&id=device-123&sid=12345678&key=\(key)"
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
                serviceData: Data([
                    2, 0x01, 4, 0xA1, 0xB2, 0xC3, 0x12, 0x34, 0x56, 0x78,
                ])
            ),
            BLESetupAdvertisement(
                mode: .setup,
                hardware: .seeedReTerminalE1004,
                hardwareSuffix: "A1B2C3",
                sessionID: Data([0x12, 0x34, 0x56, 0x78])
            )
        )
        XCTAssertEqual(
            BLESetupAdvertisement(
                serviceData: Data(repeating: 0, count: 16) + Data([
                    2, 0x02, 9, 0x11, 0x22, 0x33, 0x12, 0x34, 0x56, 0x78,
                ])
            ),
            BLESetupAdvertisement(
                mode: .maintenance,
                hardware: .waveshare133E6,
                hardwareSuffix: "112233",
                sessionID: Data([0x12, 0x34, 0x56, 0x78])
            )
        )
        XCTAssertNil(BLESetupAdvertisement(
            serviceData: Data([1, 0x01, 4, 0, 0, 1, 0, 0, 0, 1])
        ))
        XCTAssertNil(BLESetupAdvertisement(
            serviceData: Data([2, 0x01, 99, 0, 0, 1, 0, 0, 0, 1])
        ))
    }

    func testDeviceInfoValidatesConnectionNonceForScannedCode() throws {
        let code = try makeCode()
        let info = try JSONDecoder().decode(
            BLESetupDeviceInfo.self,
            from: Data(#"{"protocol":2,"id":"device-123","sid":"12345678","connection_nonce":"000102030405060708090a0b0c0d0e0f","hardware":4,"model":"reTerminal_E1004","firmware":"1.13.0","mode":"maintenance"}"#.utf8)
        )

        XCTAssertEqual(
            try info.validate(qrCode: code),
            Data(0x00...0x0F)
        )
    }

    func testDeviceInfoRejectsMissingOrShortConnectionNonce() throws {
        let code = try makeCode()
        let missing = Data(#"{"protocol":2,"id":"device-123","sid":"12345678","hardware":4,"model":"reTerminal_E1004","firmware":"1.13.0","mode":"maintenance"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(
            BLESetupDeviceInfo.self, from: missing
        ))

        let short = try JSONDecoder().decode(
            BLESetupDeviceInfo.self,
            from: Data(#"{"protocol":2,"id":"device-123","sid":"12345678","connection_nonce":"0001","hardware":4,"model":"reTerminal_E1004","firmware":"1.13.0","mode":"maintenance"}"#.utf8)
        )
        XCTAssertThrowsError(try short.validate(qrCode: code))
    }

    func testQRFrameRoundTripAndReplayProtection() throws {
        let code = try makeCode()
        let connectionNonce = Data(0xA0...0xAF)
        var sender = try BLESetupCrypto(
            qrCode: code, connectionNonce: connectionNonce
        )
        var receiver = try BLESetupCrypto(
            qrCode: code, connectionNonce: connectionNonce
        )
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
            string: "tesserae://setup?v=2&id=vector&sid=12345678&key=\(key)"
        )
        var crypto = try BLESetupCrypto(
            qrCode: code,
            connectionNonce: Data(0xA0...0xAF)
        )

        let frame = try crypto.seal(
            Data(#"{"op":"scan"}"#.utf8),
            direction: .appToDevice
        )

        XCTAssertEqual(
            frame.hexString,
            "a1000000017aa1631846fa0c8f2a24b83901d9b11e2715bd505ea24fa86062432f11"
        )
    }

    func testQRFrameAuthenticatesDirection() throws {
        let code = try makeCode()
        let connectionNonce = Data(repeating: 7, count: 16)
        var sender = try BLESetupCrypto(
            qrCode: code, connectionNonce: connectionNonce
        )
        var receiver = try BLESetupCrypto(
            qrCode: code, connectionNonce: connectionNonce
        )
        let frame = try sender.seal(Data("hello".utf8), direction: .appToDevice)

        XCTAssertThrowsError(try receiver.open(frame, direction: .deviceToApp))
    }

    func testReconnectUsesFreshKeyAndRejectsEarlierConnectionFrame() throws {
        let code = try makeCode()
        let firstNonce = Data(repeating: 0, count: 16)
        let secondNonce = Data(repeating: 1, count: 16)
        var firstSender = try BLESetupCrypto(
            qrCode: code, connectionNonce: firstNonce
        )
        var secondReceiver = try BLESetupCrypto(
            qrCode: code, connectionNonce: secondNonce
        )
        let message = Data("reconnect".utf8)
        let capturedFrame = try firstSender.seal(
            message, direction: .appToDevice
        )

        XCTAssertThrowsError(try secondReceiver.open(
            capturedFrame, direction: .appToDevice
        ))

        var secondSender = try BLESetupCrypto(
            qrCode: code, connectionNonce: secondNonce
        )
        let freshFrame = try secondSender.seal(
            message, direction: .appToDevice
        )
        XCTAssertEqual(
            try secondReceiver.open(freshFrame, direction: .appToDevice),
            message
        )
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
            string: "tesserae://setup?v=2&id=device-123&sid=12345678&key=\(key)"
        )
    }
}
