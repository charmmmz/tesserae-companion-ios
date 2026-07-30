import XCTest

@MainActor
final class TesseraeCompanionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDisplayManufacturerBadges() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "light"
        app.launch()

        assertDisplayManufacturerBadges(in: app, screenshotName: "Light Manufacturer Badges")
    }

    func testDisplayManufacturerBadgesInDarkMode() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launch()

        assertDisplayManufacturerBadges(in: app, screenshotName: "Dark Manufacturer Badges")
    }

    private func assertDisplayManufacturerBadges(
        in app: XCUIApplication,
        screenshotName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        app.buttons["Explore with Demo Data"].tap()

        XCTAssertTrue(
            app.staticTexts["Kitchen"].waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["display-hardware-picPak"].exists,
            file: file,
            line: line
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["display-hardware-seeedStudio"].exists,
            file: file,
            line: line
        )
        XCTAssertFalse(app.staticTexts["picpak"].exists, file: file, line: line)
        XCTAssertFalse(
            app.staticTexts["reterminal_e1004"].exists,
            file: file,
            line: line
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDemoJourneyAcrossMainTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Displays"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Kitchen"].exists)
        assertPreview(
            app.descendants(matching: .any)["display-preview-picpak-kitchen"],
            hasAspectRatio: 800.0 / 480.0
        )

        let kitchenCard = app.buttons["display-card-picpak-kitchen"]
        XCTAssertTrue(kitchenCard.exists)
        kitchenCard.tap()
        XCTAssertTrue(
            app.navigationBars["Kitchen"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertTrue(app.staticTexts["800 × 480"].exists)
        assertPreview(
            app.descendants(matching: .any)[
                "display-detail-preview-picpak-kitchen"
            ],
            hasAspectRatio: 800.0 / 480.0
        )
        app.navigationBars["Kitchen"].buttons["Displays"].tap()

        let deskPreview = app.descendants(matching: .any)["display-preview-e1004-desk"]
        for _ in 0..<4 where !deskPreview.exists {
            app.swipeUp()
        }
        assertPreview(deskPreview, hasAspectRatio: 1_200.0 / 1_600.0)

        tabBar.buttons["Dashboards"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))
        let dashboardPreview = app.descendants(matching: .any)[
            "dashboard-preview-pantry"
        ]
        assertPreview(
            dashboardPreview,
            hasAspectRatio: 800.0 / 480.0
        )
        let dashboardPreviewButton = app.buttons[
            "dashboard-preview-button-pantry"
        ]
        XCTAssertTrue(dashboardPreviewButton.exists)
        dashboardPreviewButton.tap()
        let previewDoneButton = app.buttons["Done"]
        XCTAssertTrue(previewDoneButton.waitForExistence(timeout: 2))
        let expandedDashboardScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        expandedDashboardScreenshot.name = "Expanded Dashboard Preview"
        expandedDashboardScreenshot.lifetime = .keepAlways
        add(expandedDashboardScreenshot)
        previewDoneButton.tap()
        XCTAssertTrue(dashboardPreviewButton.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Add to favourites"].exists)
        XCTAssertFalse(app.buttons["Remove from favourites"].exists)
        XCTAssertTrue(app.buttons["Push"].exists)
        XCTAssertFalse(app.buttons["Send Now"].exists)

        let pantryPushButton = app.buttons["dashboard-push-pantry"]
        XCTAssertTrue(pantryPushButton.exists)
        pantryPushButton.tap()
        XCTAssertTrue(
            app.navigationBars["Push Dashboard"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["Dashboard binding"].exists)
        XCTAssertTrue(app.buttons["Push to Selected Displays"].isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(pantryPushButton.waitForExistence(timeout: 2))

        let dashboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        dashboardScreenshot.name = "Dashboard Compact Previews"
        dashboardScreenshot.lifetime = .keepAlways
        add(dashboardScreenshot)

        tabBar.buttons["Send"].tap()
        app.buttons["Use Sample"].tap()
        let sendButton = app.buttons["Send to Displays"]
        XCTAssertTrue(sendButton.isEnabled)
        let sendButtonHeight = sendButton.frame.height
        sendButton.tap()

        let sentAlert = app.alerts["Sent"]
        XCTAssertTrue(sentAlert.waitForExistence(timeout: 3))
        XCTAssertEqual(
            sendButton.frame.height,
            sendButtonHeight,
            accuracy: 1
        )
        sentAlert.buttons["OK"].tap()

        tabBar.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Shared Photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Published"].exists)
        let historyStatus = app.descendants(matching: .any)[
            "history-status-history-demo-photo"
        ]
        let historyResend = app.buttons[
            "history-resend-history-demo-photo"
        ]
        XCTAssertTrue(historyStatus.exists)
        XCTAssertTrue(historyResend.exists)
        XCTAssertEqual(
            historyResend.frame.width,
            historyStatus.frame.width,
            accuracy: 1
        )
        XCTAssertEqual(historyResend.label, "Resend")
        XCTAssertFalse(app.buttons["Resend to Original Displays"].exists)

        let collapsedCard = app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "activity-photo-card-"
            )
        ).firstMatch
        XCTAssertTrue(collapsedCard.waitForExistence(timeout: 2))
        let restingCardMinY = collapsedCard.frame.minY
        let activityScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(activityScrollView.exists)
        activityScrollView.swipeDown()
        XCTAssertTrue(collapsedCard.waitForExistence(timeout: 2))
        XCTAssertEqual(
            collapsedCard.frame.minY,
            restingCardMinY,
            accuracy: 3
        )

        let collapsedHeight = collapsedCard.frame.height
        XCTAssertEqual(collapsedCard.value as? String, "Collapsed")
        collapsedCard.tap()

        XCTAssertEqual(collapsedCard.value as? String, "Expanded")
        XCTAssertGreaterThan(collapsedCard.frame.height, collapsedHeight)

        let activityScreenshot = XCTAttachment(screenshot: app.screenshot())
        activityScreenshot.name = "Expanded Activity Photo"
        activityScreenshot.lifetime = .keepAlways
        add(activityScreenshot)

        let localActivityCardIdentifier = collapsedCard.identifier
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "history-card-"
                )
            ).firstMatch.exists
        )

        app.buttons["Settings"].tap()
        let clearLocalActivityButton = app.buttons["clear-local-activity"]
        XCTAssertTrue(clearLocalActivityButton.waitForExistence(timeout: 2))
        for _ in 0..<4 where !clearLocalActivityButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(clearLocalActivityButton.isHittable)
        clearLocalActivityButton.tap()

        let confirmation = app.sheets.firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Clear Local Activity"].tap()
        XCTAssertTrue(
            app.staticTexts["Local Activity was cleared."]
                .waitForExistence(timeout: 2)
        )
        app.buttons["Done"].tap()

        XCTAssertFalse(
            app.buttons[localActivityCardIdentifier]
                .waitForExistence(timeout: 1)
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "history-card-"
                )
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts["No Activity Yet"].waitForExistence(timeout: 2)
        )

        let clearedActivityScrollView = app.scrollViews.firstMatch
        XCTAssertTrue(clearedActivityScrollView.exists)
        clearedActivityScrollView.swipeDown()
        XCTAssertTrue(
            app.staticTexts["No Activity Yet"].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "history-card-"
                )
            ).firstMatch.exists
        )
    }

    func testSlowActivityRefreshReturnsListToRestingPosition() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "1500"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"]
                .waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let activityTab = app.tabBars.firstMatch.buttons["Activity"]
        XCTAssertTrue(activityTab.waitForExistence(timeout: 15))
        activityTab.tap()

        let historyCard = app.buttons[
            "history-card-history-demo-photo"
        ].firstMatch
        XCTAssertTrue(historyCard.waitForExistence(timeout: 5))
        let restingMinY = historyCard.frame.minY

        let scrollView = app.scrollViews.firstMatch
        XCTAssertTrue(scrollView.exists)
        scrollView.swipeDown()

        XCTAssertTrue(historyCard.waitForExistence(timeout: 2))
        XCTAssertEqual(
            historyCard.frame.minY,
            restingMinY,
            accuracy: 3,
            "The list must return before the delayed server refresh finishes."
        )
    }

    func testDashboardCardsReorderWithLongPressDrag() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.tabBars.firstMatch.buttons["Dashboards"].tap()

        let morning = app.staticTexts["Morning"]
        let pantry = app.staticTexts["Pantry"]
        XCTAssertTrue(morning.waitForExistence(timeout: 2))
        XCTAssertTrue(pantry.waitForExistence(timeout: 2))
        let upper = morning.frame.minY < pantry.frame.minY
            ? morning
            : pantry
        let lower = morning.frame.minY < pantry.frame.minY
            ? pantry
            : morning

        lower.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 0.45,
            thenDragTo: upper.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)
            )
        )

        XCTAssertLessThan(lower.frame.minY, upper.frame.minY)
    }

    private func assertPreview(
        _ preview: XCUIElement,
        hasAspectRatio expectedRatio: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(preview.waitForExistence(timeout: 2), file: file, line: line)
        XCTAssertGreaterThan(preview.frame.height, 0, file: file, line: line)
        XCTAssertEqual(
            preview.frame.width / preview.frame.height,
            expectedRatio,
            accuracy: 0.03,
            file: file,
            line: line
        )
    }

    func testSimplifiedChineseOnboarding() {
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Tesserae 伴侣"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["使用演示数据体验"].exists)
        XCTAssertTrue(app.buttons["扫描配对二维码"].exists)

        app.buttons["使用演示数据体验"].tap()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["显示屏"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.buttons["仪表盘"].exists)
        XCTAssertTrue(tabBar.buttons["发送"].exists)
        XCTAssertTrue(tabBar.buttons["活动"].exists)
        XCTAssertFalse(app.staticTexts["演示数据"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["最近在线"].exists
        )
    }

    func testDemoSendShowsPreviewAndRecordsActivity() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Send"].waitForExistence(timeout: 3))
        tabBar.buttons["Send"].tap()

        let deskTarget = app.buttons.containing(
            .staticText,
            identifier: "Desk"
        ).firstMatch
        let kitchenTarget = app.buttons.containing(
            .staticText,
            identifier: "Kitchen"
        ).firstMatch
        XCTAssertTrue(deskTarget.waitForExistence(timeout: 2))
        XCTAssertTrue(kitchenTarget.exists)
        for _ in 0..<4 where !deskTarget.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deskTarget.isHittable)
        let targetList = app.staticTexts["Displays"].firstMatch
        XCTAssertTrue(targetList.waitForExistence(timeout: 2))
        let initialTargetListY = targetList.frame.minY
        deskTarget.tap()
        XCTAssertEqual(
            targetList.frame.minY,
            initialTargetListY,
            accuracy: 1
        )
        kitchenTarget.tap()
        XCTAssertEqual(
            targetList.frame.minY,
            initialTargetListY,
            accuracy: 1
        )

        app.buttons["Use Sample"].tap()
        let panelPreview = app.descendants(matching: .any)["send-panel-preview"]
        XCTAssertTrue(panelPreview.waitForExistence(timeout: 2))
        let portraitPreviewValue = (
            panelPreview.value as? String ?? ""
        ).replacingOccurrences(of: ",", with: "")
        XCTAssertTrue(portraitPreviewValue.contains("fit"))
        XCTAssertTrue(
            portraitPreviewValue.contains("1200 by 1600")
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["selected-image-preview"]
                .waitForExistence(timeout: 2)
        )
        let imagePreview = app.descendants(matching: .any)[
            "selected-image-preview"
        ]
        XCTAssertGreaterThanOrEqual(
            imagePreview.frame.minX,
            panelPreview.frame.minX - 1
        )
        XCTAssertLessThanOrEqual(
            imagePreview.frame.maxX,
            panelPreview.frame.maxX + 1
        )
        app.buttons["Fill"].tap()
        XCTAssertTrue((panelPreview.value as? String)?.contains("fill") == true)
        XCTAssertGreaterThanOrEqual(
            imagePreview.frame.minX,
            panelPreview.frame.minX - 1
        )
        XCTAssertLessThanOrEqual(
            imagePreview.frame.maxX,
            panelPreview.frame.maxX + 1
        )
        let previewScreenshot = XCTAttachment(screenshot: app.screenshot())
        previewScreenshot.name = "Send Fill Preview"
        previewScreenshot.lifetime = .keepAlways
        add(previewScreenshot)
        let previewSendButton = app.buttons["Send to Displays"]
        XCTAssertTrue(previewSendButton.isEnabled)
        let previewSendButtonHeight = previewSendButton.frame.height
        previewSendButton.tap()

        let sentAlert = app.alerts["Sent"]
        XCTAssertTrue(sentAlert.waitForExistence(timeout: 3))
        XCTAssertEqual(
            previewSendButton.frame.height,
            previewSendButtonHeight,
            accuracy: 1
        )
        sentAlert.buttons["OK"].tap()

        tabBar.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Shared Photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Published"].exists)
    }

    func testManualConnectionAgainstFixtureServer() throws {
        let baseURL = "http://127.0.0.1:18765"
        guard
            let probeURL = URL(string: "\(baseURL)/api/app/v1"),
            (try? Data(contentsOf: probeURL)) != nil
        else {
            throw XCTSkip("Start Contracts/fixture_server.py on port 18765.")
        }

        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_SERVER_URL"] = baseURL
        app.launchEnvironment["TESSERAE_PAIRING_CODE"] = "482193"
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(app.buttons["Enter Server Address"].waitForExistence(timeout: 3))
        app.buttons["Enter Server Address"].tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 2))
        app.buttons["Connect"].tap()

        let kitchen = app.staticTexts["Kitchen"]
        if !kitchen.waitForExistence(timeout: 5) {
            let alert = app.alerts["Something Went Wrong"]
            let details = alert.staticTexts.allElementsBoundByIndex
                .map { element in element.label }
                .joined(separator: " ")
            XCTFail(details.isEmpty ? "Live connection did not complete." : details)
        }
        XCTAssertFalse(app.staticTexts["Connected through Companion API"].exists)
    }

    func testLivePreviewsAgainstPairedServer() throws {
        guard ProcessInfo.processInfo.environment[
            "TESSERAE_EXPECT_LIVE_PREVIEWS"
        ] == "1" else {
            throw XCTSkip(
                "Set TESSERAE_EXPECT_LIVE_PREVIEWS on a paired physical device."
            )
        }

        let app = XCUIApplication()
        app.launch()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(
            tabBar.buttons["Displays"].waitForExistence(timeout: 10)
        )
        let displayPreview = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Last-served device preview"
                )
            )
            .firstMatch
        XCTAssertTrue(displayPreview.waitForExistence(timeout: 10))

        tabBar.buttons["Dashboards"].tap()
        let dashboardPreview = app.descendants(matching: .any)
            .matching(
                NSPredicate(
                    format: "label BEGINSWITH %@",
                    "Cached visual preview"
                )
            )
            .firstMatch
        XCTAssertTrue(dashboardPreview.waitForExistence(timeout: 20))
    }

    func testBonjourDiscoveryAgainstAdvertisedFixture() throws {
        guard ProcessInfo.processInfo.environment[
            "TESSERAE_EXPECT_BONJOUR_FIXTURE"
        ] == "1" else {
            throw XCTSkip(
                "Set TESSERAE_EXPECT_BONJOUR_FIXTURE while advertising Tesserae Fixture."
            )
        }

        addUIInterruptionMonitor(withDescription: "Local Network") { alert in
            if alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return true
            }
            return false
        }

        let app = XCUIApplication()
        app.launch()
        app.tap()

        XCTAssertTrue(
            app.staticTexts["Tesserae Fixture"].waitForExistence(timeout: 8)
        )
    }
}
