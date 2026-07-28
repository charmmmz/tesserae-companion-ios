import Foundation
import XCTest
@testable import TesseraeKit

final class BonjourDiscoveryTests: XCTestCase {
    func testDiscoversAdvertisedFixtureService() async throws {
        guard let expectedName = ProcessInfo.processInfo.environment[
            "TESSERAE_BONJOUR_EXPECT_NAME"
        ] else {
            throw XCTSkip(
                "Set TESSERAE_BONJOUR_EXPECT_NAME while advertising a local fixture."
            )
        }

        let service = BonjourDiscoveryService(
            browseDuration: .seconds(3),
            resolutionTimeout: .seconds(3)
        )
        let instances = try await service.instances()
        let discovered = try XCTUnwrap(
            instances.first(where: { $0.name == expectedName })
        )

        XCTAssertEqual(discovered.baseURL.port, 18_765)
        XCTAssertEqual(discovered.baseURL.scheme, "http")
    }
}
