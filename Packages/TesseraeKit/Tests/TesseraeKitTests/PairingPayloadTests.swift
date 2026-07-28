import XCTest
@testable import TesseraeKit

final class PairingPayloadTests: XCTestCase {
    func testRoundTripsCanonicalPairingURL() throws {
        let payload = try PairingPayload(
            baseURL: XCTUnwrap(URL(string: "http://tesserae.local:8765")),
            code: "482193"
        )

        let encoded = try PairingPayloadCodec.encode(payload)
        let decoded = try PairingPayloadCodec.decode(encoded)

        XCTAssertEqual(decoded, payload)
        XCTAssertTrue(encoded.hasPrefix("tesserae://pair?"))
        XCTAssertFalse(encoded.contains("token"))
    }

    func testDecodesJSONPayload() throws {
        let decoded = try PairingPayloadCodec.decode(
            #"{"base_url":"https://display.example.test","code":"123456"}"#
        )

        XCTAssertEqual(decoded.baseURL.absoluteString, "https://display.example.test")
        XCTAssertEqual(decoded.code, "123456")
    }

    func testRejectsLongLivedTokenOrUnrelatedQR() {
        XCTAssertThrowsError(
            try PairingPayloadCodec.decode(
                "tesserae://pair?base_url=http://example.test&token=secret"
            )
        )
        XCTAssertThrowsError(
            try PairingPayloadCodec.decode("https://example.com")
        )
    }
}
