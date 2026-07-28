import Foundation
import XCTest
@testable import TesseraeKit

final class TesseraeInstanceTests: XCTestCase {
    func testUpdatingServerVersionPreservesInstanceDetails() throws {
        let baseURL = try XCTUnwrap(
            URL(string: "https://tesserae.example.test")
        )
        let instance = TesseraeInstance(
            id: "instance-home",
            name: "Home",
            baseURL: baseURL,
            serverVersion: "0.207.0",
            timezone: "Asia/Shanghai",
            webURL: "https://tesserae.example.test/settings"
        )

        let updated = instance.updatingServerVersion(to: "0.209.0")

        XCTAssertEqual(updated.id, instance.id)
        XCTAssertEqual(updated.name, instance.name)
        XCTAssertEqual(updated.baseURL, instance.baseURL)
        XCTAssertEqual(updated.serverVersion, "0.209.0")
        XCTAssertEqual(updated.timezone, instance.timezone)
        XCTAssertEqual(updated.webURL, instance.webURL)
    }
}
