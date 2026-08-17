import XCTest
@testable import Tesserae_Companion

@MainActor
final class MessageCenterTests: XCTestCase {
    func testHapticEventAdvancesForRepeatedSemanticFeedback() {
        var event = TesseraeHapticEvent()

        event.trigger(.selection)
        let firstRevision = event.revision
        event.trigger(.selection)

        XCTAssertEqual(event.feedback, .selection)
        XCTAssertEqual(event.revision, firstRevision + 1)
    }

    func testMessageRetainsExplicitHapticIntent() {
        let center = TesseraeMessageCenter()

        center.post(
            TesseraeMessage(
                id: "send.submission",
                text: "Sent",
                kind: .success,
                haptic: .success
            )
        )

        XCTAssertEqual(center.currentMessage?.haptic, .success)
    }

    func testMessageCanKeepDetailedAccessibilityTextOffTheCapsule() {
        let center = TesseraeMessageCenter()
        let detail = "The server closed the connection before responding."

        center.post(
            TesseraeMessage(
                id: "connection.status",
                text: "Unable to connect to Tesserae",
                accessibilityText: detail
            )
        )

        XCTAssertEqual(
            center.currentMessage?.text,
            "Unable to connect to Tesserae"
        )
        XCTAssertEqual(center.currentMessage?.accessibilityText, detail)
    }

    func testPostingTheSameIdentifierReplacesInsteadOfStacking() {
        let center = TesseraeMessageCenter()

        center.post(
            TesseraeMessage(
                id: "gallery.uploads",
                text: "Uploading 1 of 3",
                kind: .progress(fraction: 1 / 3),
                lifetime: .persistent
            )
        )
        center.post(
            TesseraeMessage(
                id: "gallery.uploads",
                text: "Uploading 2 of 3",
                kind: .progress(fraction: 2 / 3),
                lifetime: .persistent
            )
        )

        XCTAssertEqual(center.queuedCount, 1)
        XCTAssertEqual(center.currentMessage?.text, "Uploading 2 of 3")
    }

    func testHigherPriorityMessageDisplaysFirst() {
        let center = TesseraeMessageCenter()

        center.post(
            TesseraeMessage(
                id: "send.accepted",
                text: "Sent",
                lifetime: .persistent,
                priority: .normal
            )
        )
        center.post(
            TesseraeMessage(
                id: "connection.status",
                text: "Offline",
                lifetime: .persistent,
                priority: .high
            )
        )

        XCTAssertEqual(center.currentMessage?.id, "connection.status")
        center.dismiss(id: "connection.status")
        XCTAssertEqual(center.currentMessage?.id, "send.accepted")
    }

    func testAutomaticLifetimeStartsOnlyWhenMessageBecomesVisible() async {
        let center = TesseraeMessageCenter()
        center.activateHost(id: UUID())
        center.post(
            TesseraeMessage(
                id: "connection.status",
                text: "Offline",
                lifetime: .persistent,
                priority: .high
            )
        )
        center.post(
            TesseraeMessage(
                id: "send.accepted",
                text: "Sent",
                lifetime: .automatic(seconds: 0.04),
                priority: .normal
            )
        )

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(center.queuedCount, 2)

        center.dismiss(id: "connection.status")
        XCTAssertEqual(center.currentMessage?.id, "send.accepted")

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(center.currentMessage)
    }

    func testTopmostPresentationHostOwnsTheVisibleMessage() {
        let center = TesseraeMessageCenter()
        let rootHost = UUID()
        let sheetHost = UUID()

        center.activateHost(id: rootHost)
        XCTAssertTrue(center.isActiveHost(id: rootHost))

        center.activateHost(id: sheetHost)
        XCTAssertFalse(center.isActiveHost(id: rootHost))
        XCTAssertTrue(center.isActiveHost(id: sheetHost))

        center.deactivateHost(id: sheetHost)
        XCTAssertTrue(center.isActiveHost(id: rootHost))
    }

    func testTransientMessageDoesNotReplayAfterItsSheetCloses() {
        let center = TesseraeMessageCenter()
        let rootHost = UUID()
        let sheetHost = UUID()
        center.activateHost(id: rootHost)
        center.activateHost(id: sheetHost)
        center.post(
            TesseraeMessage(
                id: "send.submission",
                text: "Sent",
                lifetime: .automatic(seconds: 3)
            )
        )

        XCTAssertEqual(center.currentMessage?.id, "send.submission")
        center.deactivateHost(id: sheetHost)

        XCTAssertNil(center.currentMessage)
        XCTAssertTrue(center.isActiveHost(id: rootHost))
    }

    func testPersistentMessageHandsOffWhenItsSheetCloses() {
        let center = TesseraeMessageCenter()
        let rootHost = UUID()
        let sheetHost = UUID()
        center.activateHost(id: rootHost)
        center.activateHost(id: sheetHost)
        center.post(
            TesseraeMessage(
                id: "gallery.uploads",
                text: "Uploading 2 of 5",
                lifetime: .persistent
            )
        )

        center.deactivateHost(id: sheetHost)

        XCTAssertEqual(center.currentMessage?.id, "gallery.uploads")
        XCTAssertTrue(center.isActiveHost(id: rootHost))
    }
}
