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

    func testPicPakAdvertisementUsesMaintenanceHardwareCatalog() throws {
        let advertisement = try XCTUnwrap(BLESetupAdvertisement(
            serviceData: Data([2, 0x02, 11, 0xA1, 0xB2, 0xC3, 1, 2, 3, 4])
        ))
        XCTAssertEqual(advertisement.mode, .maintenance)
        XCTAssertEqual(advertisement.hardware, .picPak42)
        XCTAssertEqual(advertisement.hardware.catalogKind, "picpak_4_2")
    }

    func testRefreshSpeedDiagnosticsDecodeSupportedValuesWithoutNetwork() {
        for speed in BLERefreshSpeed.allCases {
            let diagnostics = NearbyDeviceDiagnostics(event: [
                "firmware": "0.9.3",
                "refresh_speed": speed.rawValue,
                "wifi_configured": true,
            ])
            XCTAssertEqual(diagnostics.refreshSpeed, speed)
            XCTAssertTrue(diagnostics.isWiFiConfigured)
            XCTAssertNil(diagnostics.ipAddress)
            XCTAssertEqual(diagnostics.rssi, 0)
        }
    }

    func testRefreshSpeedIgnoresMissingUnknownAndMalformedValues() {
        for event: [String: Any] in [[:], ["refresh_speed": "future"], ["refresh_speed": 5]] {
            let diagnostics = NearbyDeviceDiagnostics(event: event)
            XCTAssertNil(diagnostics.refreshSpeed)
            var setting = NearbyRefreshSpeedSetting()
            setting.receiveDiagnostics(diagnostics.refreshSpeed, hardware: .picPak42)
            XCTAssertNil(setting.confirmedValue)
            XCTAssertFalse(setting.beginSaving(.fiveSeconds))
        }
    }

    func testRefreshSpeedIsNotEnabledForOtherHardware() {
        var setting = NearbyRefreshSpeedSetting()
        setting.receiveDiagnostics(.native, hardware: .seeedReTerminalE1004)
        XCTAssertNil(setting.confirmedValue)
        XCTAssertFalse(setting.beginSaving(.fiveSeconds))
    }

    func testRefreshSpeedRetainsConfirmedValueUntilMatchingAcknowledgement() {
        var setting = NearbyRefreshSpeedSetting()
        setting.receiveDiagnostics(.native, hardware: .picPak42)
        XCTAssertFalse(setting.beginSaving(.native))
        XCTAssertTrue(setting.beginSaving(.fiveSeconds))
        XCTAssertEqual(setting.confirmedValue, .native)
        XCTAssertTrue(setting.isSaving)
        XCTAssertFalse(setting.beginSaving(.tenSeconds))
        XCTAssertFalse(setting.acknowledge("future"))
        XCTAssertFalse(setting.acknowledge("10s"))
        XCTAssertFalse(setting.acknowledge(nil))
        XCTAssertEqual(setting.confirmedValue, .native)

        setting.receiveDiagnostics(.fiveSeconds, hardware: .picPak42)
        XCTAssertEqual(setting.confirmedValue, .native)
        XCTAssertTrue(setting.acknowledge("5s"))
        XCTAssertEqual(setting.confirmedValue, .fiveSeconds)
        XCTAssertFalse(setting.isSaving)
    }

    func testRefreshSpeedSaveFailureAllowsRetryWithoutChangingConfirmedValue() {
        var setting = NearbyRefreshSpeedSetting()
        setting.receiveDiagnostics(.tenSeconds, hardware: .picPak42)
        XCTAssertTrue(setting.beginSaving(.fiveSeconds))
        setting.fail("Settings could not be saved.")
        XCTAssertEqual(setting.confirmedValue, .tenSeconds)
        XCTAssertEqual(setting.errorMessage, "Settings could not be saved.")
        XCTAssertFalse(setting.isSaving)
        XCTAssertTrue(setting.beginSaving(.fiveSeconds))
        XCTAssertNil(setting.errorMessage)
    }

    func testRefreshSpeedTimeoutRequiresReadbackAndIgnoresLateAcknowledgement() {
        var setting = NearbyRefreshSpeedSetting()
        setting.receiveDiagnostics(.native, hardware: .picPak42)
        XCTAssertTrue(setting.beginSaving(.fiveSeconds))
        setting.fail("Save not confirmed.", needsReadback: true)
        XCTAssertEqual(setting.confirmedValue, .native)
        XCTAssertTrue(setting.needsReadback)
        XCTAssertFalse(setting.acknowledge("5s"))
        XCTAssertFalse(setting.beginSaving(.fiveSeconds))
        XCTAssertFalse(setting.beginSaving(.tenSeconds))

        // Persistence can have succeeded even if its acknowledgement timed out.
        setting.receiveDiagnostics(.fiveSeconds, hardware: .picPak42)
        XCTAssertEqual(setting.confirmedValue, .fiveSeconds)
        XCTAssertFalse(setting.needsReadback)
        XCTAssertNil(setting.errorMessage)
        XCTAssertTrue(setting.beginSaving(.tenSeconds))
    }

    func testRefreshSpeedDisconnectClearsStateBeforeDifferentDeviceReconnects() {
        var setting = NearbyRefreshSpeedSetting()
        setting.receiveDiagnostics(.fiveSeconds, hardware: .picPak42)
        XCTAssertTrue(setting.beginSaving(.native))
        setting.reset()
        XCTAssertNil(setting.confirmedValue)
        XCTAssertNil(setting.pendingValue)
        XCTAssertNil(setting.errorMessage)
        XCTAssertFalse(setting.acknowledge("native"))
        XCTAssertFalse(setting.beginSaving(.tenSeconds))

        setting.receiveDiagnostics(nil, hardware: .seeedReTerminalE1004)
        XCTAssertNil(setting.confirmedValue)
        setting.reset()
        setting.receiveDiagnostics(.tenSeconds, hardware: .picPak42)
        XCTAssertEqual(setting.confirmedValue, .tenSeconds)
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
