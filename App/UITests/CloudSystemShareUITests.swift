import XCTest

@MainActor final class CloudSystemShareUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_RUN_CLOUD_SYSTEM_UI"] == "1",
            "Opt in with the isolated A4 fixture and owned Photos simulator.")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        let namespace = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_EXISTING_NAMESPACE"] ?? "a4-system-\(UUID().uuidString)"
        app.launchEnvironment["TESSERAE_SYSTEM_ENTRY_FIXTURE"] = "1"
        app.launchEnvironment["TESSERAE_CLOUD_ISSUER"] = "http://127.0.0.1:8877"
        app.launchEnvironment["TESSERAE_CLOUD_BROWSER_ENTRY"] = "http://127.0.0.1:8879/begin"
        app.launchEnvironment["TESSERAE_CLOUD_TEST_NAMESPACE"] = namespace
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        print("A4_SYSTEM_NAMESPACE", namespace)
        app.launch()
        return app
    }

    private func authorize(_ app: XCUIApplication) async throws {
        if app.buttons["cloud-device-a4_land"].waitForExistence(timeout: 2) { return }
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8879/select?account=owner_a")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let signIn = app.buttons["cloud-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15)); reveal(signIn, in: app); signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20))
        app.buttons["Account"].tap()
        let tenant = app.buttons["A4 Studio A (owner)"]
        XCTAssertTrue(tenant.waitForExistence(timeout: 5)); tenant.tap(); allow.tap()
        XCTAssertTrue(app.buttons["cloud-device-a4_land"].waitForExistence(timeout: 15))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !element.isHittable {
            let surface = app.scrollViews.containing(.any, identifier: element.identifier).allElementsBoundByIndex.last ?? app
            let above = element.exists && element.frame.midY < surface.frame.midY
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: above ? 0.25 : 0.8))
                .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: above ? 0.8 : 0.25)))
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func openCloudLivePhotoShare() async throws -> XCUIApplication {
        let app = launch()
        try await authorize(app)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        print("A4_MAIN_APP_AFTER_TERMINATE", app.state.rawValue)
        let photos = XCUIApplication(bundleIdentifier: "com.apple.mobileslideshow")
        photos.terminate(); photos.launch()
        if photos.buttons["Continue"].waitForExistence(timeout: 2) { photos.buttons["Continue"].tap() }
        let share = photos.buttons["PUOneUpBarButtonItemIdentifierShare"]
        if !share.exists {
            let live = photos.images.matching(NSPredicate(format: "label BEGINSWITH 'Live Photo,'")).firstMatch
            XCTAssertTrue(live.waitForExistence(timeout: 8))
            live.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5)); share.tap()
        let activity = photos.cells["Tesserae"]
        XCTAssertTrue(activity.waitForExistence(timeout: 8)); activity.tap()
        let landscape = photos.buttons["share-display-cloud:a4_land"]
        if !landscape.waitForExistence(timeout: 15) {
            capture(photos, "A4-cloud-share-load-failure"); print("A4_SHARE_LOAD_AX", photos.debugDescription)
        }
        XCTAssertTrue(landscape.exists)
        return photos
    }

    func testPhotosLivePhotoSendsFixedCloudTargetsWithoutForegroundApp() async throws {
        let photos = try await openCloudLivePhotoShare()
        let landscape = photos.buttons["share-display-cloud:a4_land"]
        let portrait = photos.buttons["share-display-cloud:a4_portrait"]
        XCTAssertTrue(landscape.isSelected)
        reveal(portrait, in: photos)
        if !portrait.isSelected { portrait.tap() }
        let initialPicker = photos.descendants(matching: .any)["share-preview-display-picker"].firstMatch
        reveal(initialPicker, in: photos); initialPicker.tap(); photos.buttons["share-preview-display-a4_portrait"].tap()
        let timeline = photos.descendants(matching: .any)["media-frame-timeline"].firstMatch
        XCTAssertTrue(timeline.waitForExistence(timeout: 15)); reveal(timeline, in: photos)
        timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: timeline.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: photos.buttons["share-send"])
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 10), .completed)
        let canvas = photos.descendants(matching: .any)["share-panel-preview"].firstMatch
        reveal(canvas, in: photos)
        let zoom = photos.staticTexts["send-framing-zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 8))
        let initial = zoom.label
        canvas.pinch(withScale: 1.5, velocity: 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)))
        let crop = zoom.label
        XCTAssertNotEqual(crop, initial)
        capture(photos, "A4-system-share-portrait-crop")
        let picker = photos.descendants(matching: .any)["share-preview-display-picker"].firstMatch
        reveal(picker, in: photos); picker.tap(); photos.buttons["share-preview-display-a4_land"].tap()
        XCTAssertNotEqual(zoom.label, crop)
        picker.tap(); photos.buttons["share-preview-display-a4_portrait"].tap()
        XCTAssertEqual(zoom.label, crop)
        let send = photos.buttons["share-send"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: send)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed)
        send.tap()
        let first = photos.descendants(matching: .any)["share-cloud-result-a4_land"].firstMatch
        if !first.waitForExistence(timeout: 35) {
            capture(photos, "A4-system-share-after-submit"); print("A4_SHARE_RESULT_AX", photos.debugDescription)
        }
        XCTAssertTrue(first.exists)
        let second = photos.descendants(matching: .any)["share-cloud-result-a4_portrait"].firstMatch
        reveal(second, in: photos)
        XCTAssertTrue(first.label.contains("Frame Generated"))
        XCTAssertTrue(second.label.contains("Frame Generated"))
        capture(photos, "A4-system-share-durable-results")
        photos.buttons["share-cloud-done"].tap()
    }
    func testPhotosOversizedCloudCanvasRetainsInputWithoutSending() async throws {
        let photos = try await openCloudLivePhotoShare()
        let land = photos.buttons["share-display-cloud:a4_land"]
        for row in photos.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'share-display-cloud:'")).allElementsBoundByIndex
            where row.identifier != land.identifier && row.isSelected {
            reveal(row, in: photos); row.tap()
        }
        reveal(land, in: photos)
        if !land.isSelected { land.tap() }
        let send = photos.buttons["share-send"]
        XCTAssertTrue(send.isEnabled); send.tap()
        let retained = photos.staticTexts["Not Sent"]
        if !retained.waitForExistence(timeout: 35) {
            capture(photos, "A4-retained-canvas-failure"); print("A4_RETAINED_AX", photos.debugDescription)
        }
        XCTAssertTrue(retained.exists)
        XCTAssertTrue(photos.staticTexts["This photo needs more memory than a system action can use. It has been kept for review in Tesserae Companion."].exists)
        capture(photos, "A4-real-Photos-retained-memory-budget")
        photos.buttons["share-cloud-done"].tap()
    }

    func testPhotosCloudComposerFinalBadgeReadOnly() async throws {
        let photos = try await openCloudLivePhotoShare()
        let land = photos.buttons["share-display-cloud:a4_land"]
        reveal(land, in: photos)
        capture(photos, "A4-real-Photos-Cloud-targets-final-badge")
        photos.buttons["share-cancel"].tap()
    }

}
