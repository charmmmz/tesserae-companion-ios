import XCTest

@MainActor
final class AlbumsAndActivityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testAlbumCleanCancelAndUnsavedNameProtection() {
        let app = launchDemo()
        openAlbum(app)
        app.buttons["offline-album-exit"].tap()
        XCTAssertTrue(app.buttons["gallery-grid-options"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.alerts["Discard Changes?"].exists)

        openAlbumFromFolder(app)
        let name = app.textFields["offline-album-name"]
        name.tap()
        name.typeText(" Updated")
        app.buttons["offline-album-exit"].tap()
        XCTAssertTrue(app.alerts["Discard Changes?"].waitForExistence(timeout: 3))
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertEqual(name.value as? String, "family Updated")
        app.buttons["offline-album-exit"].tap()
        app.alerts.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["gallery-grid-options"].waitForExistence(timeout: 3))
        openAlbumFromFolder(app)
        XCTAssertEqual(app.textFields["offline-album-name"].value as? String, "family")
    }

    func testAlbumOrderSurvivesBackAndProtectsNestedDismissal() {
        let app = launchDemo()
        openAlbum(app)
        openPhotoOrder(app)
        let folderOrder = app.buttons["offline-album-folder-order"]
        XCTAssertTrue(folderOrder.waitForExistence(timeout: 3))
        folderOrder.tap()
        XCTAssertFalse(folderOrder.isEnabled)
        XCTAssertFalse(app.buttons["Apply"].exists)

        swipeDownSheet(app, title: "Photo Order")
        XCTAssertTrue(app.alerts["Discard Changes?"].waitForExistence(timeout: 3))
        attach(app, name: "Album nested order draft protection")
        app.alerts.buttons["Keep Editing"].tap()
        XCTAssertTrue(app.navigationBars["Photo Order"].exists)
        XCTAssertFalse(folderOrder.isEnabled)

        app.navigationBars["Photo Order"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["offline-album-photo-order-link"].waitForExistence(timeout: 3))
        openPhotoOrder(app)
        XCTAssertFalse(folderOrder.isEnabled)
        swipeDownSheet(app, title: "Photo Order")
        app.alerts.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["gallery-grid-options"].waitForExistence(timeout: 3))
    }

    func testAlbumReviewBackSaveAndCleanReopen() {
        let app = launchDemo()
        openAlbum(app)
        let target = app.buttons["offline-album-target-e1004-desk"]
        XCTAssertTrue(target.waitForExistence(timeout: 3))
        target.tap()
        let reviewSave = app.buttons["offline-album-review-save"]
        reviewSave.tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-album-review"].waitForExistence(timeout: 3))
        attach(app, name: "Album readiness paper background")
        app.buttons["offline-album-exit"].tap()
        XCTAssertTrue(app.textFields["offline-album-name"].waitForExistence(timeout: 3))
        openPhotoOrder(app)
        app.buttons["offline-album-folder-order"].tap()
        app.navigationBars["Photo Order"].buttons.firstMatch.tap()

        reviewSave.tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-album-review"].waitForExistence(timeout: 3))
        attach(app, name: "Album review")
        app.buttons["offline-album-exit"].tap()
        XCTAssertFalse(app.alerts["Discard Changes?"].exists)
        openPhotoOrder(app)
        XCTAssertFalse(app.buttons["offline-album-folder-order"].isEnabled)
        app.navigationBars["Photo Order"].buttons.firstMatch.tap()
        reviewSave.tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-album-review"].waitForExistence(timeout: 3))
        reviewSave.tap()
        XCTAssertTrue(app.buttons["offline-album-summary"].waitForExistence(timeout: 4))
        app.buttons["offline-album-summary"].tap()
        XCTAssertTrue(app.textFields["offline-album-name"].waitForExistence(timeout: 3))
        XCTAssertFalse(reviewSave.exists)
        app.buttons["offline-album-exit"].tap()
        XCTAssertFalse(app.alerts["Discard Changes?"].exists)
        XCTAssertTrue(app.buttons["offline-album-summary"].waitForExistence(timeout: 3))
    }

    func testActivityFilterRestoresNormalHistory() {
        let app = launchDemo()
        app.tabBars.firstMatch.buttons["Activity"].tap()
        let history = app.buttons["history-card-history-demo-photo"]
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        app.buttons["activity-filter"].tap()
        app.buttons["activity-filter-needs-attention"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["activity-attention-empty"].waitForExistence(timeout: 3))
        XCTAssertFalse(history.exists)
        attach(app, name: "Activity needs attention empty state")
        app.buttons["activity-filter"].tap()
        app.buttons["activity-filter-all"].tap()
        XCTAssertTrue(history.waitForExistence(timeout: 3))
        attach(app, name: "Activity all records")
    }

    func testDarkLargeTextAlbumAndActivityLayout() {
        let app = launchDemo(largeText: true, dark: true)
        app.tabBars.firstMatch.buttons["Activity"].tap()
        XCTAssertTrue(app.buttons["activity-filter"].waitForExistence(timeout: 3))
        attach(app, name: "Activity dark accessibility text")
        openAlbum(app)
        attach(app, name: "Album dark accessibility text")
        let target = app.buttons["offline-album-target-e1004-desk"]
        reveal(target, in: app)
        target.tap()
        app.buttons["offline-album-review-save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["offline-album-review"].waitForExistence(timeout: 3))
        for identifier in ["offline-album-exit", "offline-album-review-save"] {
            let button = app.buttons[identifier]
            let insideWindow = XCTNSPredicateExpectation(
                predicate: NSPredicate { element, _ in
                    guard let element = element as? XCUIElement else { return false }
                    return element.isHittable && app.frame.contains(element.frame)
                },
                object: button
            )
            XCTAssertEqual(XCTWaiter.wait(for: [insideWindow], timeout: 3), .completed)
        }
        attach(app, name: "Album review dark accessibility text")
        XCTAssertTrue(app.buttons["offline-album-exit"].isHittable)
        XCTAssertTrue(app.buttons["offline-album-review-save"].isHittable)
    }

    private func launchDemo(largeText: Bool = false, dark: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = dark ? "dark" : "light"
        app.launchArguments += ["-AppleLocale", "en_GB", "-AppleLanguages", "(en)"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 4))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.buttons["Library"].waitForExistence(timeout: 3))
        return app
    }

    private func openAlbum(_ app: XCUIApplication) {
        app.tabBars.firstMatch.buttons["Library"].tap()
        let family = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(family.waitForExistence(timeout: 3))
        family.tap()
        openAlbumFromFolder(app)
    }

    private func openAlbumFromFolder(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["gallery-grid-options"].waitForExistence(timeout: 3))
        app.buttons["gallery-grid-options"].tap()
        let setup = app.buttons["Set Up Offline Album"]
        XCTAssertTrue(setup.waitForExistence(timeout: 3))
        setup.tap()
        XCTAssertTrue(app.textFields["offline-album-name"].waitForExistence(timeout: 3))
    }

    private func openPhotoOrder(_ app: XCUIApplication) {
        let order = app.buttons["offline-album-photo-order-link"]
        reveal(order, in: app)
        order.tap()
        XCTAssertTrue(app.navigationBars["Photo Order"].waitForExistence(timeout: 3))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }

    private func swipeDownSheet(_ app: XCUIApplication, title: String) {
        let start = app.navigationBars[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
