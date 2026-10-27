import XCTest
import UIKit

@MainActor
final class BluetoothShareUITests: XCTestCase {
    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func launch(unified: Bool = false, noReceipt: Bool = false, unauthorized: Bool = false,
                        systemShare: Bool = false, accessibilityText: Bool = false, unifiedTargets: Bool = false,
                        absent: Bool = false, delayed: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if delayed { app.launchEnvironment["TESSERAE_UI_TEST_BLUETOOTH_DISCOVERY_DELAY_MS"] = "6000" }
        if unifiedTargets { app.launchEnvironment["TESSERAE_UI_TEST_UNIFIED_SHARE_TARGETS"] = "1" }
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_BLUETOOTH_SHARE"] = "1"
        app.launchEnvironment[unified ? "TESSERAE_UI_TEST_UNIFIED_BLE" : "TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launchEnvironment[unified ? "TESSERAE_UI_TEST_UNIFIED_PHOTO" : "TESSERAE_UI_TEST_PICPAK_PHOTO"] = absent ? "0" : "1"
        if noReceipt { app.launchEnvironment["TESSERAE_UI_TEST_SKIP_PHOTO_RECEIPT"] = "1" }
        if unauthorized { app.launchEnvironment["TESSERAE_UI_TEST_PHOTO_UNAUTHORIZED"] = "1" }
        if systemShare { app.launchEnvironment["TESSERAE_UI_TEST_SYSTEM_SHARE"] = "1" }
        app.launch()
        return app
    }

    func testSystemShareOpensBluetoothComposer() {
        let app = launch(systemShare: true)
        app.buttons["Open System Share Sheet"].tap()
        let share = app.cells["Tesserae"]
        XCTAssertTrue(share.waitForExistence(timeout: 8))
        share.tap()
        XCTAssertTrue(app.staticTexts["Displays"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.segmentedControls["share-destination-picker"].exists)
        XCTAssertTrue(app.images["Shared photo"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "System Share Extension Bluetooth Destination"; shot.lifetime = .keepAlways; add(shot)
    }

    private func chooseDisplay(_ app: XCUIApplication) {
        let device = app.buttons["share-display-nearby:00000000-0000-0000-0000-000000000011"]
        XCTAssertTrue(device.waitForExistence(timeout: 8))
        device.tap()
    }

    private func send(_ app: XCUIApplication) {
        let button = app.buttons["share-send"]
        XCTAssertTrue(button.waitForExistence(timeout: 8))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        for _ in 0..<4 where !button.isHittable { app.swipeUp() }
        button.tap()
    }

    func testAuthorizedPicPakPhotoCompletesAfterReceipt() {
        let app = launch()
        chooseDisplay(app)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Unified Share Composer"; shot.lifetime = .keepAlways; add(shot)
        send(app)
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 15))
    }

    func testUnifiedDeviceListUsesBluetoothBadgeAndKeepsAssociatedDeviceInOneRow() {
        let app = launch(unifiedTargets: true)
        let bluetooth = app.buttons["share-display-picpak-f85b1ba1b2c3"]
        let server = app.buttons["share-display-living-room"]
        XCTAssertTrue(bluetooth.waitForExistence(timeout: 8))
        XCTAssertTrue(server.exists)
        XCTAssertTrue((bluetooth.value as? String)?.contains("Bluetooth") == true)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'share-display-'" )).count, 2)
        XCTAssertFalse(app.segmentedControls["share-destination-picker"].exists)
        server.tap()
        bluetooth.tap()
        XCTAssertFalse(server.isSelected)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Unified Server and Bluetooth Device List"; shot.lifetime = .keepAlways; add(shot)
        send(app)
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 15))
    }

    func testUnifiedPhotoUsesNegotiatedPanel() {
        let app = launch(unified: true)
        chooseDisplay(app)
        let resolution = app.descendants(matching: .any)["share-preview-display-picker"].firstMatch
        XCTAssertTrue(resolution.waitForExistence(timeout: 8))
        XCTAssertTrue(resolution.label.contains("1600") || resolution.label.contains("1,600"))
        send(app)
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 25))
    }

    func testSavedBluetoothDisplayNeverFallsBackToServerWhenNotNearby() {
        let app = launch(unifiedTargets: true, absent: true)
        let target = app.buttons["share-display-picpak-f85b1ba1b2c3"]
        XCTAssertTrue(target.waitForExistence(timeout: 8))
        XCTAssertFalse(target.isEnabled)
        XCTAssertFalse(target.isSelected)
        XCTAssertTrue((target.value as? String)?.contains("Bluetooth") == true)
        XCTAssertFalse(app.buttons["share-send"].isEnabled)
        XCTAssertFalse(app.buttons["share-display-living-room"].isSelected)
        XCTAssertFalse(app.staticTexts["Not nearby"].exists)
    }

    func testAllBytesAcknowledgedKeepsPageOpenWithoutReceipt() {
        let app = launch(noReceipt: true)
        chooseDisplay(app)
        send(app)
        XCTAssertTrue(app.staticTexts["Waiting for display confirmation…"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["share-test-complete"].exists)
        XCTAssertFalse(app.buttons["share-cancel"].isEnabled)
        let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'share-display-'"))
        XCTAssertFalse(selection.firstMatch.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Bluetooth Share Awaiting Device Receipt"; shot.lifetime = .keepAlways; add(shot)
        // A failed transfer must release draft protection so the user can retry or cancel.
        let unlocked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                 object: app.buttons["share-cancel"])
        XCTAssertEqual(XCTWaiter.wait(for: [unlocked], timeout: 30), .completed)
        XCTAssertFalse(app.staticTexts["share-test-complete"].exists)
    }

    func testUnauthorizedDisplayStaysInShareAndRequiresMainApp() {
        let app = launch(unauthorized: true)
        chooseDisplay(app)
        XCTAssertTrue(app.otherElements["share-bluetooth-error"].waitForExistence(timeout: 5)
            || app.staticTexts["share-bluetooth-error"].exists)
        XCTAssertFalse(app.buttons["share-send"].isEnabled)
        XCTAssertFalse(app.staticTexts["share-test-complete"].exists)
        XCTAssertTrue(app.buttons["share-cancel"].isEnabled)
    }

    func testComposerKeepsSelectionWhenRotatedAtAccessibilitySize() {
        let app = launch(accessibilityText: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        chooseDisplay(app)
        XCTAssertTrue(app.descendants(matching: .any)["share-preview-display-picker"].firstMatch.waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        var previous = CGRect.zero
        var stableObservations = 0
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            stableObservations = frame == previous ? stableObservations + 1 : 0
            previous = frame
            // The app supports landscape on iPad; its iPhone host remains portrait.
            return (UIDevice.current.userInterfaceIdiom != .pad || frame.width > frame.height)
                && stableObservations >= 3
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Bluetooth Share Landscape Accessibility"; shot.lifetime = .keepAlways; add(shot)
        send(app)
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 15))
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            let scroll = app.scrollViews.containing(.button, identifier: element.identifier).firstMatch
            let container = scroll.exists ? scroll : app
            let start = container.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
            let end = container.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.2))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable)
    }

    func testSavedBluetoothIsDisabledUntilDiscoveredWithoutConnectionLogs() {
        let app = launch(unifiedTargets: true, delayed: true)
        let target = app.buttons["share-display-picpak-f85b1ba1b2c3"]
        XCTAssertTrue(target.waitForExistence(timeout: 4))
        XCTAssertFalse(target.isEnabled)
        XCTAssertFalse(target.isSelected)
        let disabledShot = XCTAttachment(screenshot: app.screenshot())
        disabledShot.name = "Bluetooth Target Before Discovery"; disabledShot.lifetime = .keepAlways; add(disabledShot)
        let discovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [discovered], timeout: 12), .completed)
        target.tap()
        XCTAssertFalse(app.staticTexts["Connecting securely…"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'PicPak/'")).firstMatch.exists)
        send(app)
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 15))
    }

    func testInAppBluetoothDiscoveryAndExclusiveSelectionSend() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_PHOTO"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_SEND_BLUETOOTH"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_BLUETOOTH_DISCOVERY_DELAY_MS"] = "6000"
        app.launchEnvironment["TESSERAE_UI_TEST_MEDIA"] = "video"
        app.launch()
        app.buttons["Explore with Demo Data"].tap()
        app.buttons["root-send-action"].tap()
        let target = app.buttons["send-display-picpak-kitchen"]
        XCTAssertTrue(target.waitForExistence(timeout: 6))
        XCTAssertFalse(target.isEnabled)
        XCTAssertFalse(target.isSelected)
        let disabledShot = XCTAttachment(screenshot: app.screenshot())
        disabledShot.name = "Bluetooth Target Before Discovery"; disabledShot.lifetime = .keepAlways; add(disabledShot)
        let discovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [discovered], timeout: 12), .completed)
        let server = app.buttons["send-display-e1004-desk"]
        reveal(server, app: app)
        server.tap()
        target.tap()
        XCTAssertTrue(target.isSelected)
        XCTAssertFalse(server.isSelected)
        server.tap()
        XCTAssertFalse(target.isSelected)
        XCTAssertTrue(server.isSelected)
        target.tap()
        let selectionShot = XCTAttachment(screenshot: app.screenshot())
        selectionShot.name = "In App Exclusive Bluetooth Selection"; selectionShot.lifetime = .keepAlways; add(selectionShot)
        let panelReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS '400×300'"), object: target)
        XCTAssertEqual(XCTWaiter.wait(for: [panelReady], timeout: 8), .completed)
        let button = app.buttons["send-submit"]
        reveal(button, app: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["send-success-banner"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["send-submit"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "In App Bluetooth Exclusive Send Confirmation"; shot.lifetime = .keepAlways; add(shot)
    }

}
