import XCTest

@MainActor
final class TesseraeCompanionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testOnboardingOffersDiscoveryAndManualConnectionWithoutQR() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.staticTexts[
                "The official Tesserae app for quick, everyday display tasks on iPhone."
            ].exists
        )
        XCTAssertTrue(app.buttons["Enter Server Address"].exists)
        XCTAssertFalse(app.buttons["Scan Pairing QR"].exists)
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

    func testDemoActivityUsesCompactPreviewCards() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.tabBars.firstMatch.buttons["Activity"].tap()

        let historyStatus = app.descendants(matching: .any)[
            "history-status-history-demo-photo"
        ]
        let historyPreview = app.descendants(matching: .any)[
            "history-preview-history-demo-photo"
        ]
        let historyResend = app.buttons[
            "history-resend-history-demo-photo"
        ]
        XCTAssertTrue(historyStatus.waitForExistence(timeout: 3))
        XCTAssertEqual(historyStatus.label, "Published")
        XCTAssertEqual(
            app.descendants(matching: .any)[
                "history-status-history-demo-dashboard"
            ].label,
            "Dispatched"
        )
        XCTAssertTrue(historyPreview.exists)
        XCTAssertTrue(historyResend.exists)
        assertPreview(
            historyPreview,
            hasAspectRatio: 1_200.0 / 1_600.0
        )
        assertPreview(
            app.descendants(matching: .any)[
                "history-preview-history-demo-dashboard"
            ],
            hasAspectRatio: 800.0 / 480.0
        )

        let sharedPhotoTitle = app.staticTexts["Shared Photo"].firstMatch
        XCTAssertGreaterThan(
            historyPreview.frame.minX,
            sharedPhotoTitle.frame.maxX
        )
        XCTAssertGreaterThan(
            historyStatus.frame.midX,
            historyPreview.frame.midX
        )
        XCTAssertLessThan(
            historyStatus.frame.midY,
            historyPreview.frame.midY
        )
        XCTAssertLessThan(historyResend.frame.width, 112)
        XCTAssertEqual(historyResend.label, "Resend")
        XCTAssertFalse(app.buttons["Resend to Original Displays"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Activity Compact Cards Dark"
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
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "display-pending-indicator-picpak-kitchen"
            ].exists
        )

        let kitchenCard = app.buttons["display-card-picpak-kitchen"]
        XCTAssertTrue(kitchenCard.exists)
        kitchenCard.tap()
        XCTAssertTrue(
            app.navigationBars["Kitchen"].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.navigationBars["Kitchen"].buttons["Close"].exists)
        XCTAssertFalse(app.navigationBars["Kitchen"].buttons["Displays"].exists)
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "display-pending-status-picpak-kitchen"
            ].exists
        )
        XCTAssertTrue(app.staticTexts["800 × 480"].exists)
        assertPreview(
            app.descendants(matching: .any)[
                "display-detail-preview-picpak-kitchen"
            ],
            hasAspectRatio: 800.0 / 480.0
        )
        let screenCarousel = app.descendants(matching: .any)[
            "display-screen-carousel-picpak-kitchen"
        ]
        XCTAssertTrue(screenCarousel.exists)
        screenCarousel.swipeLeft()
        XCTAssertTrue(
            app.staticTexts["Next Screen"].waitForExistence(timeout: 2)
        )
        assertPreview(
            app.descendants(matching: .any)[
                "display-detail-pending-preview-picpak-kitchen"
            ],
            hasAspectRatio: 800.0 / 480.0
        )
        app.navigationBars["Kitchen"].buttons["Close"].tap()
        XCTAssertTrue(
            app.staticTexts["Kitchen"].waitForExistence(timeout: 2)
        )

        let deskPreview = app.descendants(matching: .any)["display-preview-e1004-desk"]
        for _ in 0..<4 where !deskPreview.exists {
            app.swipeUp()
        }
        assertPreview(deskPreview, hasAspectRatio: 1_200.0 / 1_600.0)

        tabBar.buttons["Dashboards"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))
        let dashboardPreviewButton = app.buttons[
            "dashboard-preview-button-pantry"
        ]
        XCTAssertTrue(dashboardPreviewButton.waitForExistence(timeout: 2))
        let previewLoaded = NSPredicate(format: "isEnabled == true")
        expectation(
            for: previewLoaded,
            evaluatedWith: dashboardPreviewButton
        )
        waitForExpectations(timeout: 2)
        let followingDashboardPreviewButton = app.buttons[
            "dashboard-preview-button-morning"
        ]
        XCTAssertTrue(followingDashboardPreviewButton.exists)
        let collapsedFollowingDashboardY = followingDashboardPreviewButton.frame.minY
        XCTAssertEqual(
            dashboardPreviewButton.value as? String,
            "Collapsed"
        )
        dashboardPreviewButton.tap()
        XCTAssertEqual(
            dashboardPreviewButton.value as? String,
            "Expanded"
        )
        XCTAssertGreaterThan(
            followingDashboardPreviewButton.frame.minY,
            collapsedFollowingDashboardY
        )
        let expandedDashboardScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        expandedDashboardScreenshot.name = "Inline Dashboard Preview"
        expandedDashboardScreenshot.lifetime = .keepAlways
        add(expandedDashboardScreenshot)
        dashboardPreviewButton.tap()
        XCTAssertEqual(
            dashboardPreviewButton.value as? String,
            "Collapsed"
        )
        XCTAssertFalse(app.buttons["Add to favourites"].exists)
        XCTAssertFalse(app.buttons["Remove from favourites"].exists)
        XCTAssertTrue(app.buttons["Push"].exists)
        XCTAssertFalse(app.buttons["Send Now"].exists)

        let pantryPushButton = app.buttons["dashboard-push-pantry"]
        XCTAssertTrue(pantryPushButton.exists)
        pantryPushButton.tap()
        let pushDashboardTitle = app.staticTexts[
            "dashboard-push-sheet-title"
        ]
        XCTAssertTrue(pushDashboardTitle.waitForExistence(timeout: 2))
        XCTAssertGreaterThan(
            pushDashboardTitle.frame.minY,
            app.frame.height * 0.2,
            "A short Dashboard Push should fit its content instead of opening full height."
        )
        XCTAssertFalse(
            app.staticTexts[
                "Choose one or more displays already bound to this dashboard."
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "dashboard-push-preview-pantry"
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Bound Displays"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "dashboard-push-device-picpak-kitchen"
            ].exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "dashboard-push-device-e1004-desk"
            ].exists
        )
        let pushToSelectedDisplays = app.buttons[
            "Push to Selected Displays"
        ]
        XCTAssertTrue(pushToSelectedDisplays.isEnabled)
        XCTAssertLessThan(
            pushToSelectedDisplays.frame.maxY,
            app.frame.maxY,
            "The fitted sheet must keep its primary action fully visible."
        )
        let dashboardPushScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        dashboardPushScreenshot.name = "Bound Dashboard Push Sheet"
        dashboardPushScreenshot.lifetime = .keepAlways
        add(dashboardPushScreenshot)
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
        let historyStatus = app.descendants(matching: .any)[
            "history-status-history-demo-photo"
        ]
        let historyPreview = app.descendants(matching: .any)[
            "history-preview-history-demo-photo"
        ]
        let historyResend = app.buttons[
            "history-resend-history-demo-photo"
        ]
        XCTAssertTrue(historyStatus.exists)
        XCTAssertEqual(historyStatus.label, "Published")
        XCTAssertTrue(historyPreview.exists)
        XCTAssertTrue(historyResend.exists)
        let sharedPhotoTitle = app.staticTexts["Shared Photo"].firstMatch
        XCTAssertGreaterThan(
            historyPreview.frame.minX,
            sharedPhotoTitle.frame.maxX
        )
        XCTAssertGreaterThan(
            historyStatus.frame.midX,
            historyPreview.frame.midX
        )
        XCTAssertLessThan(
            historyStatus.frame.midY,
            historyPreview.frame.midY
        )
        XCTAssertLessThan(historyResend.frame.width, 112)
        XCTAssertEqual(historyResend.label, "Resend")
        XCTAssertFalse(app.buttons["Resend to Original Displays"].exists)

        let compactActivityScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        compactActivityScreenshot.name = "Activity Compact Cards"
        compactActivityScreenshot.lifetime = .keepAlways
        add(compactActivityScreenshot)

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
        XCTAssertFalse(
            app.staticTexts[
                "Clears Activity on this iPhone, including locally displayed server History. Tesserae server History is not deleted."
            ].exists
        )
        clearLocalActivityButton.tap()

        let confirmation = app.alerts["Clear Local Activity?"]
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

    func testDisplayDetailsOpenAsSheet() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let kitchenCard = app.buttons["display-card-picpak-kitchen"]
        XCTAssertTrue(kitchenCard.waitForExistence(timeout: 3))
        kitchenCard.tap()

        let detailNavigation = app.navigationBars["Kitchen"]
        XCTAssertTrue(detailNavigation.waitForExistence(timeout: 2))
        XCTAssertTrue(detailNavigation.buttons["Close"].exists)
        XCTAssertFalse(detailNavigation.buttons["Displays"].exists)
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "display-screen-page-indicator-picpak-kitchen"
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Spectra 6 · 6-color"].exists)
        XCTAssertFalse(app.staticTexts["Waveshare E6"].exists)

        detailNavigation.buttons["Close"].tap()
        XCTAssertTrue(kitchenCard.waitForExistence(timeout: 2))
    }

    func testDemoSendSupportsLinkActions() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.tabBars.firstMatch.buttons["Send"].tap()

        XCTAssertTrue(app.buttons["Link"].waitForExistence(timeout: 2))
        app.buttons["Link"].tap()
        XCTAssertTrue(app.buttons["Image URL"].exists)
        XCTAssertTrue(app.buttons["Webpage Snapshot"].exists)

        let linkField = app.textFields["send-link-url"]
        XCTAssertTrue(linkField.exists)
        linkField.tap()
        linkField.typeText("https://example.com/news")

        let sendButton = app.buttons["Send to Displays"]
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let sentAlert = app.alerts["Sent"]
        XCTAssertTrue(sentAlert.waitForExistence(timeout: 3))
        XCTAssertTrue(
            sentAlert.staticTexts[
                "Tesserae accepted the link. Follow its progress in Activity."
            ].exists
        )
        sentAlert.buttons["OK"].tap()

        app.tabBars.firstMatch.buttons["Activity"].tap()
        XCTAssertTrue(
            app.staticTexts["example.com/news"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Webpage"].exists)
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

        let deskTarget = app.buttons["send-display-e1004-desk"]
        let kitchenTarget = app.buttons["send-display-picpak-kitchen"]
        XCTAssertTrue(deskTarget.waitForExistence(timeout: 2))
        XCTAssertTrue(kitchenTarget.exists)
        XCTAssertTrue(app.buttons["Stretch"].exists)
        XCTAssertTrue(app.buttons["Center"].exists)
        XCTAssertFalse(app.buttons["More"].exists)
        let previewPicker = app.buttons["send-preview-display-picker"]
        XCTAssertTrue(previewPicker.waitForExistence(timeout: 2))
        XCTAssertFalse(previewPicker.isEnabled)
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
        XCTAssertTrue(previewPicker.isEnabled)
        let previewPickerFrame = previewPicker.frame
        previewPicker.tap()
        let kitchenPreviewOption = app.buttons["Kitchen"]
        XCTAssertTrue(kitchenPreviewOption.waitForExistence(timeout: 2))
        kitchenPreviewOption.tap()
        XCTAssertEqual(
            previewPicker.frame.maxX,
            previewPickerFrame.maxX,
            accuracy: 1
        )
        XCTAssertGreaterThan(
            previewPicker.frame.width,
            previewPickerFrame.width
        )
        let targetListYBeforeKitchenToggle = targetList.frame.minY
        kitchenTarget.tap()
        XCTAssertEqual(
            targetList.frame.minY,
            targetListYBeforeKitchenToggle,
            accuracy: 1
        )
        XCTAssertFalse(previewPicker.isEnabled)
        kitchenTarget.tap()
        XCTAssertTrue(previewPicker.isEnabled)
        previewPicker.tap()
        let deskPreviewOption = app.buttons["Desk"]
        XCTAssertTrue(deskPreviewOption.waitForExistence(timeout: 2))
        deskPreviewOption.tap()

        app.buttons["Use Sample"].tap()
        let changePhoto = app.buttons["send-change-photo"]
        XCTAssertTrue(changePhoto.waitForExistence(timeout: 2))
        let previewMetadata = app.descendants(matching: .any)[
            "send-preview-metadata"
        ]
        XCTAssertTrue(previewMetadata.exists)
        XCTAssertTrue(previewMetadata.label.contains("×"))
        XCTAssertTrue(previewMetadata.label.contains("·"))
        XCTAssertFalse(previewMetadata.label.contains("Desk"))
        XCTAssertTrue(app.staticTexts["Previewing on"].exists)
        XCTAssertLessThan(changePhoto.frame.maxY, previewPicker.frame.minY)
        let panelPreview = app.descendants(matching: .any)["send-panel-preview"]
        XCTAssertTrue(panelPreview.waitForExistence(timeout: 2))
        let portraitPreviewValue = (
            panelPreview.value as? String ?? ""
        ).replacingOccurrences(of: ",", with: "")
        XCTAssertTrue(portraitPreviewValue.contains("fill"))
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
        XCTAssertTrue(
            app.descendants(matching: .any)["send-framing-hint"]
                .waitForExistence(timeout: 2)
        )
        let framingZoom = app.descendants(matching: .any)[
            "send-framing-zoom"
        ]
        let resetFraming = app.descendants(matching: .any)[
            "send-framing-reset"
        ]
        XCTAssertTrue(framingZoom.exists)
        XCTAssertTrue(resetFraming.exists)
        let initialZoom = framingZoom.label
        XCTAssertFalse(resetFraming.isEnabled)
        let leadingPreviewGutter = imagePreview.frame.minX
            - panelPreview.frame.minX
        XCTAssertGreaterThan(leadingPreviewGutter, 4)
        let framingBeforeOutsideDrag = panelPreview.value as? String
        let outsideDragStart = panelPreview.coordinate(
            withNormalizedOffset: CGVector(dx: 0, dy: 0)
        ).withOffset(
            CGVector(
                dx: leadingPreviewGutter / 2,
                dy: imagePreview.frame.midY - panelPreview.frame.minY
            )
        )
        let outsideDragEnd = outsideDragStart.withOffset(
            CGVector(dx: min(20, leadingPreviewGutter / 3), dy: 0)
        )
        outsideDragStart.press(
            forDuration: 0.05,
            thenDragTo: outsideDragEnd
        )
        XCTAssertEqual(
            panelPreview.value as? String,
            framingBeforeOutsideDrag
        )
        imagePreview.pinch(withScale: 1.6, velocity: 1)
        expectation(
            for: NSPredicate(format: "isHittable == true"),
            evaluatedWith: resetFraming
        )
        waitForExpectations(timeout: 3)
        XCTAssertNotEqual(framingZoom.label, initialZoom)
        XCTAssertTrue(resetFraming.isEnabled)
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
        XCTAssertTrue(
            app.descendants(matching: .any).matching(
                NSPredicate(
                    format: "identifier BEGINSWITH %@",
                    "history-status-"
                )
            ).firstMatch.exists
        )
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
