import XCTest
@testable import TesseraeKit

final class DashboardIconNameTests: XCTestCase {
    func testCanonicalNameKeepsCurrentPhosphorIdentifier() {
        XCTAssertEqual(DashboardIconName.canonical("cooking-pot"), "cooking-pot")
    }

    func testCanonicalNameNormalizesPrefixAndLegacyAlias() {
        XCTAssertEqual(DashboardIconName.canonical(" ph-circle-wavy-check "), "seal-check")
    }

    func testCanonicalNameRejectsEmptyValue() {
        XCTAssertNil(DashboardIconName.canonical(" ph- "))
        XCTAssertNil(DashboardIconName.canonical(nil))
    }

    func testDisplayAndDashboardIconsShareCanonicalization() {
        XCTAssertEqual(
            PhosphorIconName.canonical(" ph-device-tablet "),
            "device-tablet"
        )
    }
}
