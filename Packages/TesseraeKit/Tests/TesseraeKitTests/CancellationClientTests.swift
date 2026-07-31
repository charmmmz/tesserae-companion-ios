import Foundation
import XCTest
@testable import TesseraeKit

final class CancellationClientTests: XCTestCase {
    func testCancelledURLRequestRemainsCancellation() async throws {
        let client = LiveTesseraeClient(
            credentials: InMemoryCredentialStore(),
            identity: TesseraeClientIdentity(
                appVersion: "0.1.0",
                installationID: "cancellation-test"
            ),
            transport: CancelledTransport()
        )

        do {
            _ = try await client.probe(
                baseURL: try XCTUnwrap(
                    URL(string: "https://tesserae.example")
                )
            )
            XCTFail("Expected the request to be cancelled.")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "Expected CancellationError, got \(error)"
            )
        }
    }
}

private struct CancelledTransport: TesseraeHTTPTransporting {
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        throw NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )
    }
}
