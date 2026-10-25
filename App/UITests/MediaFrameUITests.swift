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

    private func launch(_ kind: String, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        if !kind.isEmpty { app.launchEnvironment["TESSERAE_UI_TEST_MEDIA"] = kind }
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
                                    "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        }
        app.launch()
        let demo = app.buttons[largeText ? "使用演示数据体验" : "Explore with Demo Data"]
        XCTAssertTrue(demo.waitForExistence(timeout: 8))
        for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        let send = app.buttons["root-send-action"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 12))
        send.tap()
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

    private func scrub(_ timeline: XCUIElement) {
        let previous = timeline.value as? String
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
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
        scrub(frames)
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
        let change = app.buttons["media-choose-frame"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        XCTAssertFalse(timeline(app).exists)
        capture("Live Photo Default Key Photo", app: app)
        reveal(change, in: app)
        change.tap()
        let frames = timeline(app)
        XCTAssertTrue(frames.waitForExistence(timeout: 10))
        reveal(frames, in: app)
        scrub(frames)
        capture("Inline Live Photo Frame Selection", app: app)
        let key = app.buttons["media-restore-key-photo"]
        XCTAssertTrue(key.isHittable)
        key.tap()
        XCTAssertFalse(frames.exists)
        XCTAssertEqual(change.label, "Choose Frame")
    }

    func testLivePhotoLargeChineseTextKeepsInlineControlsReachable() {
        let app = launch("live", largeText: true)
        let change = app.buttons["media-choose-frame"]
        XCTAssertTrue(change.waitForExistence(timeout: 10))
        reveal(change, in: app)
        XCTAssertEqual(change.label, "换一帧")
        change.tap()
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
        XCTAssertTrue(app.staticTexts["Photo Sent"].waitForExistence(timeout: 15))
    }
}
