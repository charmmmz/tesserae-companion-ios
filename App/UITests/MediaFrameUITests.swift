import XCTest

@MainActor final class MediaFrameUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        if testRun?.hasSucceeded == false {
            let app = XCUIApplication()
            capture("Media Frame Failure", app: app)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Media Frame Failure Hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
    }

    private func launch(_ kind: String, largeText: Bool = false, bluetooth: Bool = false,
                        systemShare: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        if !kind.isEmpty { app.launchEnvironment["TESSERAE_UI_TEST_MEDIA"] = kind }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                    "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        }
        if bluetooth {
            app.launchEnvironment["TESSERAE_UI_TEST_BLUETOOTH_SHARE"] = "1"
            app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
            app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_PHOTO"] = "1"
        }
        if systemShare { app.launchEnvironment["TESSERAE_UI_TEST_SYSTEM_SHARE"] = "1" }
        app.launch()
        if !bluetooth {
            let demo = app.buttons[largeText ? "使用演示数据体验" : "Explore with Demo Data"]
            XCTAssertTrue(demo.waitForExistence(timeout: 8))
            for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
            demo.tap()
            let send = app.buttons["root-send-action"].firstMatch
            XCTAssertTrue(send.waitForExistence(timeout: 12))
            send.tap()
        }
        return app
    }

    private func timeline(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["media-frame-timeline"].firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable {
            let region = app.scrollViews.containing(.any, identifier: element.identifier).allElementsBoundByIndex.last
            let surface: XCUIElement = region ?? app
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8))
            start.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25)))
        }
        XCTAssertTrue(element.isHittable)
    }

    private func scrub(_ timeline: XCUIElement, velocity: XCUIGestureVelocity = .default) {
        let previous = timeline.value as? String
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)),
                   withVelocity: velocity, thenHoldForDuration: 0)
        XCTAssertNotEqual(timeline.value as? String, previous)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVideoTimelineSelectsFrameAndSendsFromExistingPreview() {
        let app = launch("video")
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 12))
        reveal(frames, in: app)
        scrub(frames, velocity: XCUIGestureVelocity(rawValue: 60))
        XCTAssertFalse(app.buttons["Use This Frame"].exists)
        capture("Inline Video Frame Selection", app: app)
        let send = app.buttons["send-submit"]
        reveal(send, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        send.tap()
        XCTAssertTrue(app.buttons["root-send-action"].firstMatch.waitForExistence(timeout: 8))
    }

    func testLivePhotoStartsWithPrimaryAndCanRestoreIt() {
        let app = launch("live")
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["media-choose-frame"].exists)
        XCTAssertTrue(app.buttons["media-restore-key-photo"].isSelected)
        reveal(frames, in: app)
        capture("Live Photo Default Expanded Timeline", app: app)
        scrub(frames)
        capture("Inline Live Photo Frame Selection", app: app)
        let key = app.buttons["media-restore-key-photo"]
        XCTAssertTrue(key.isHittable)
        key.tap()
        XCTAssertTrue(frames.exists)
        XCTAssertTrue(key.isSelected)
        capture("Live Photo Restored Key Photo", app: app)
    }

    func testLivePhotoLargeChineseTextKeepsInlineControlsReachable() {
        let app = launch("live", largeText: true)
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 10))
        reveal(frames, in: app)
        capture("Inline Live Photo Large Chinese Text", app: app)
        let key = app.buttons["media-restore-key-photo"]
        XCTAssertTrue(key.isHittable)
        XCTAssertGreaterThanOrEqual(key.frame.width, 44)
        key.tap()
        reveal(app.buttons["send-submit"], in: app)
    }

    func testUnavailableSharedLiveMotionOffersPickerAndPreservesKeyPhotoOnCancel() {
        let app = launch("live-unavailable", bluetooth: true)
        let key = app.buttons["media-restore-key-photo"]
        XCTAssertTrue(key.waitForExistence(timeout: 12))
        XCTAssertTrue(key.isSelected)
        let recovery = app.buttons["media-reselect-live-photo"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 12))
        reveal(recovery, in: app)
        capture("Share Live Photo Motion Recovery", app: app)
        recovery.tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 12))
        cancel.tap()
        XCTAssertTrue(key.waitForExistence(timeout: 8))
        XCTAssertTrue(key.isSelected)
        let device = app.buttons["share-display-nearby:00000000-0000-0000-0000-000000000011"]
        reveal(device, in: app)
        device.tap()
        let send = app.buttons["share-send"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
    }

    func testBluetoothSendsSelectedVideoFrame() {
        let app = launch("video", bluetooth: true)
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 12))
        reveal(frames, in: app)
        scrub(frames)
        let device = app.buttons["share-display-nearby:00000000-0000-0000-0000-000000000011"]
        reveal(device, in: app)
        device.tap()
        let send = app.buttons["share-send"]
        XCTAssertTrue(send.waitForExistence(timeout: 8))
        reveal(send, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        send.tap()
        XCTAssertTrue(app.staticTexts["share-test-complete"].waitForExistence(timeout: 15))
    }

    func testSystemVideoShareExposesSameInlineTimeline() {
        let app = launch("video", bluetooth: true, systemShare: true)
        let open = app.buttons["Open System Share Sheet"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 12), .completed)
        open.tap()
        let activity = app.cells["Tesserae"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        activity.tap()
        XCTAssertTrue(app.staticTexts["Displays"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.segmentedControls["share-destination-picker"].exists)
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 12))
        reveal(frames, in: app)
        scrub(frames)
        capture("System Video Share Inline Timeline", app: app)
    }

    func testNearbyBluetoothSelectsAndSendsVideoFrame() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_MEDIA"] = "video"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_PHOTO"] = "1"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 8))
        reveal(nearby, in: app)
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        let start = app.buttons["ble-photo-start"]
        XCTAssertTrue(start.waitForExistence(timeout: 8))
        start.tap()
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 12))
        reveal(frames, in: app)
        scrub(frames)
        let send = app.buttons["ble-send-photo"]
        reveal(send, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ble-photo-sent"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["ble-send-photo"].exists)
        XCTAssertFalse(app.staticTexts["Sending photo…"].exists)
    }
}
