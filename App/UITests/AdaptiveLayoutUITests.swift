import XCTest

@MainActor
final class AdaptiveLayoutUITests: XCTestCase {
    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            XCUIDevice.shared.orientation = .portrait
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            XCUIDevice.shared.orientation = .portrait
        }
    }

    private func demo(accessibilityText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-dashboardLayoutMode", "cards"]
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "500"
        app.launchEnvironment["TESSERAE_UI_TEST_AUTO_FRAMING"] = "1"
        app.launch()
        let demo = app.buttons["Explore with Demo Data"]
        XCTAssertTrue(demo.waitForExistence(timeout: 8))
        reveal(demo, app: app)
        demo.tap()
        // CI can spend several seconds taking a single accessibility snapshot.
        // Wait for readiness without adding a fixed delay to successful launches.
        let homeIsReady = app.buttons["root-send-action"].firstMatch.waitForExistence(timeout: 30)
        if !homeIsReady {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Demo startup failure"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Demo startup accessibility hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        XCTAssertTrue(homeIsReady, "Demo did not reach the home screen before the startup deadline")
        return app
    }

    private func capture(_ name: String, app: XCUIApplication) {
        // XCUI's orientation command can return while Core Animation is still
        // presenting the rotation. Wait for stable window bounds before recording.
        var previous = CGRect.zero
        var stableObservations = 0
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = app.windows.firstMatch.frame
            stableObservations = frame == previous ? stableObservations + 1 : 0
            previous = frame
            return stableObservations >= 2
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let identifier = element.identifier.isEmpty ? element.label : element.identifier
        let region = app.scrollViews.containing(.button, identifier: identifier).firstMatch
        for _ in 0..<6 where !element.isHittable {
            if region.exists, region.identifier == "dashboard-list" {
                // Duo can place system navigation on the side; list scrolling
                // does not need the photo composer's edge-only gesture.
                region.swipeUp()
            } else if region.exists {
                // Scroll at the content edge: dragging the photo itself intentionally
                // edits framing, especially with accessibility text on a large sheet.
                let start = region.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
                let end = region.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else {
                app.swipeUp()
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        // A destination can exist while its tab or sheet transition still blocks
        // interaction, particularly on older simulator runtimes.
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in element.exists && element.isHittable },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func expandDashboardSection(_ sectionID: String, app: XCUIApplication) {
        let list = app.scrollViews["dashboard-list"]
        waitUntilHittable(list)
        let group = app.buttons["dashboard-section-toggle-\(sectionID)"]
        for _ in 0..<6 where !group.exists { list.swipeUp() }
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        reveal(group, app: app)
        // Group preferences survive app launches, including other UI tests.
        if group.value as? String == "Collapsed" { group.tap() }
        XCTAssertEqual(group.value as? String, "Expanded")
    }

    func testAccessibilityComposerKeepsSendReachable() {
        let app = demo(accessibilityText: true)
        let rootSend = app.buttons["root-send-action"].firstMatch
        XCTAssertTrue(rootSend.isHittable)
        XCTAssertEqual(app.buttons.matching(identifier: "root-send-action").count, 1)
        XCTAssertGreaterThanOrEqual(rootSend.frame.width, 44)
        XCTAssertGreaterThanOrEqual(rootSend.frame.height, 44)
        XCTAssertGreaterThan(rootSend.frame.minY, app.frame.midY)
        XCTAssertGreaterThan(rootSend.frame.minX, app.frame.midX)
        XCTAssertEqual(app.frame.maxX - rootSend.frame.maxX, 16, accuracy: 1)
        capture("Accessibility root Send", app: app)
        rootSend.tap()
        let sample = app.buttons["Use Sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        reveal(sample, app: app)
        sample.tap()
        let send = app.buttons["send-submit"]
        reveal(send, app: app)
        XCTAssertTrue(send.isEnabled)
        XCTAssertGreaterThan(send.frame.width, 44)
        XCTAssertLessThanOrEqual(send.frame.maxX, app.frame.maxX)
        capture("Accessibility composer", app: app)
    }

    func testDashboardUsesFullWidthAndModalPush() {
        let app = demo()
        app.buttons["Dashboards"].firstMatch.tap()
        let list = app.scrollViews["dashboard-list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(list.frame.width, app.frame.width * 0.8)
        capture("Dashboard overview", app: app)

        expandDashboardSection("shared", app: app)
        let shared = app.buttons["dashboard-push-photo-frame-shared"]
        for _ in 0..<6 where !shared.exists { list.swipeUp() }
        XCTAssertTrue(shared.waitForExistence(timeout: 3))
        reveal(shared, app: app)
        shared.tap()
        let title = app.staticTexts["dashboard-push-sheet-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertFalse(list.isHittable)
        let desk = app.buttons["dashboard-push-device-e1004-desk"]
        reveal(desk, app: app)
        desk.tap()
        let push = app.buttons["Push to Kitchen"]
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        XCTAssertTrue(push.isEnabled)
        let cancel = app.buttons["Cancel"]
        let web = app.descendants(matching: .any)["dashboard-open-web"].firstMatch
        for action in [cancel, web] {
            XCTAssertTrue(action.isHittable)
            XCTAssertGreaterThanOrEqual(action.frame.width, 44 - 0.01)
            XCTAssertGreaterThanOrEqual(action.frame.height, 44 - 0.01)
        }
        capture("Dashboard push modal", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(push.isEnabled)
        app.buttons["Cancel"].tap()
        waitUntilHittable(list)
    }

    func testAccessibilityDashboardModalKeepsActionReachable() {
        let app = demo(accessibilityText: true)
        app.buttons["Dashboards"].firstMatch.tap()
        let push = app.buttons["dashboard-push-pantry-display-picpak-kitchen"]
        let list = app.scrollViews["dashboard-list"]
        expandDashboardSection("display-picpak-kitchen", app: app)
        for _ in 0..<6 where !push.exists { list.swipeUp() }
        XCTAssertTrue(push.waitForExistence(timeout: 5))
        reveal(push, app: app)
        push.tap()
        let submit = app.buttons["Push to Kitchen"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertTrue(submit.isHittable)
        XCTAssertGreaterThanOrEqual(submit.frame.height, 44)
        XCTAssertLessThanOrEqual(submit.frame.maxY, app.frame.maxY)
        let cancel = app.buttons["Cancel"]
        let title = app.staticTexts["dashboard-push-sheet-title"]
        XCTAssertTrue(cancel.isHittable)
        XCTAssertLessThan(cancel.frame.maxY, title.frame.minY)
        capture("Accessibility Dashboard modal", app: app)
        app.buttons["Cancel"].tap()
        waitUntilHittable(list)
    }

    func testLineupsCanReturnToDisplays() {
        let app = demo()
        let manage = app.buttons["manage-lineups"]
        let create = app.buttons["lineup-create"]
        for _ in 0..<2 {
            manage.tap()
            XCTAssertTrue(create.waitForExistence(timeout: 5))
            let explicitBack = app.buttons["lineups-back-to-displays"]
            let back = explicitBack.exists
                ? explicitBack
                : app.navigationBars["Lineups"].buttons["Displays"]
            XCTAssertTrue(back.isHittable)
            if explicitBack.exists { capture("Lineups return action", app: app) }
            back.tap()
            let returned = XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in !create.exists && manage.isHittable }, object: nil
            )
            XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        }

        manage.tap()
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        let kitchen = app.buttons["display-card-picpak-kitchen"]
        if kitchen.isHittable {
            // A wide window keeps the sidebar visible. Selecting a display must
            // leave Lineups instead of keeping its old destination over the detail.
            kitchen.tap()
            XCTAssertTrue(app.navigationBars["Kitchen"].waitForExistence(timeout: 5))
            XCTAssertFalse(create.exists)
        }
    }

    func testSelectedDisplaySurvivesDeviceTurn() {
        let app = demo()
        let kitchen = app.buttons["display-card-picpak-kitchen"]
        XCTAssertTrue(kitchen.waitForExistence(timeout: 5))
        kitchen.tap()
        XCTAssertTrue(app.navigationBars["Kitchen"].waitForExistence(timeout: 5))
        let send = app.buttons["root-send-action"]
        XCTAssertEqual(app.buttons.matching(identifier: "root-send-action").count, 1)
        XCTAssertTrue(send.isHittable)
        XCTAssertGreaterThan(send.frame.minX, app.frame.midX)
        XCTAssertGreaterThan(send.frame.minY, app.frame.midY)
        capture("Display detail portrait", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.navigationBars["Kitchen"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertEqual(app.buttons.matching(identifier: "root-send-action").count, 1)
        XCTAssertTrue(send.isHittable)
        XCTAssertGreaterThan(send.frame.minX, app.frame.midX)
        XCTAssertGreaterThan(send.frame.minY, app.frame.midY)
        capture("Display detail after device turn", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.navigationBars["Kitchen"].waitForExistence(timeout: 5))
    }

    func testLinkDraftAndSingleSubmissionSurviveDeviceTurn() {
        let app = demo()
        app.buttons["root-send-action"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Link"].waitForExistence(timeout: 5))
        app.buttons["Link"].tap()
        let field = app.textFields["send-link-url"]
        field.tap()
        field.typeText("https://example.com/adaptive-draft\n")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(field.value as? String, "https://example.com/adaptive-draft")
        capture("Link draft after device turn", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(field.value as? String, "https://example.com/adaptive-draft")
        let send = app.buttons["send-submit"]
        reveal(send, app: app)
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["send-success-banner"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
        app.buttons["Activity"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["example.com/adaptive-draft"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "example.com/adaptive-draft").count, 1)
    }

    func testLineupDraftSurvivesDeviceTurnAndProtectsExit() {
        let app = demo()
        app.buttons["manage-lineups"].tap()
        let create = app.buttons["lineup-create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let cycle = app.buttons["lineup-intent-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 5))
        reveal(cycle, app: app)
        cycle.tap()
        let name = app.textFields["lineup-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Adaptive draft")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(name.value as? String, "Adaptive draft")
        capture("Lineup draft after device turn", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(name.value as? String, "Adaptive draft")
        app.buttons["lineup-editor-exit"].tap()
        XCTAssertTrue(app.alerts["Discard Changes?"].waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertEqual(name.value as? String, "Adaptive draft")
    }

    func testPhotoFramingSurvivesDeviceTurn() {
        let app = demo()
        app.buttons["root-send-action"].firstMatch.tap()
        let sample = app.buttons["Use Sample"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        reveal(sample, app: app)
        sample.tap()
        let zoom = app.staticTexts["send-framing-zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        let before = zoom.label
        let target = app.descendants(matching: .any)["send-preview-display-picker"].label
        capture("Photo composer initial", app: app)
        let kitchen = app.buttons["send-display-picpak-kitchen"]
        let desk = app.buttons["send-display-e1004-desk"]
        reveal(kitchen, app: app)
        reveal(desk, app: app)
        XCTAssertEqual(kitchen.frame.height, 44, accuracy: 1)
        XCTAssertEqual(desk.frame.height, 44, accuracy: 1)
        let rows = [kitchen.frame, desk.frame].sorted { $0.minY < $1.minY }
        XCTAssertEqual(rows[1].minY - rows[0].maxY, 0, accuracy: 1)
        capture("Compact display selection", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(zoom.label, before)
        XCTAssertEqual(app.descendants(matching: .any)["send-preview-display-picker"].label, target)
        capture("Photo composer after device turn", app: app)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertEqual(zoom.label, before)
        capture("Photo composer portrait", app: app)
        let reset = app.buttons["send-framing-reset"]
        reveal(reset, app: app)
        reset.tap()
        XCTAssertEqual(zoom.label, "1.0×")
        capture("Photo composer compact targets", app: app)
    }
}
