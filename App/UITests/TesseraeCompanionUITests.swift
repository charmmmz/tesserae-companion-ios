import XCTest

@MainActor
final class TesseraeCompanionUITests: XCTestCase {
    private var restoreVoiceOverEnabled: Bool?

    override func tearDown() async throws {
#if compiler(>=6.4)
        try await MainActor.run {
            if #available(iOS 27.0, *), let restoreVoiceOverEnabled {
                let service = XCUIDevice.shared.voiceOverService
                if restoreVoiceOverEnabled { try service.enable() } else { try service.disable() }
            }
        }
#endif
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDashboardSearchFindsCollapsedContentAndRestoresGroups() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchArguments += ["-dashboardLayoutMode", "cards"]
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        let dashboardsTab = app.buttons["Dashboards"].firstMatch
        XCTAssertTrue(dashboardsTab.waitForExistence(timeout: 3))
        dashboardsTab.tap()
        let group = app.buttons["dashboard-section-toggle-display-picpak-kitchen"]
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        if group.value as? String != "Collapsed" { group.tap() }
        XCTAssertEqual(group.value as? String, "Collapsed")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("  PANTRY  ")
        let pantry = app.staticTexts["dashboard-title-pantry-display-picpak-kitchen"]
        XCTAssertTrue(pantry.waitForExistence(timeout: 3))
        XCTAssertTrue(pantry.isHittable)
        XCTAssertFalse(app.staticTexts["dashboard-title-photo-frame-display-picpak-kitchen"].exists)
        app.buttons["dashboard-push-pantry-display-picpak-kitchen"].tap()
        let webLink = app.descendants(matching: .any)["dashboard-open-web"]
        XCTAssertTrue(webLink.waitForExistence(timeout: 3))
        XCTAssertTrue(webLink.isHittable)
        XCTAssertEqual(webLink.label, "Open in Tesserae")
        let preview = XCTAttachment(screenshot: app.screenshot())
        preview.name = "Dashboard web shortcut"
        preview.lifetime = .keepAlways
        add(preview)
        app.buttons["Cancel"].firstMatch.tap()
        search.tap()
        search.buttons["Clear text"].tap()
        search.tap()
        search.typeText("NoSuchDashboard")
        XCTAssertTrue(app.descendants(matching: .any)["dashboard-search-empty"].exists)
        search.buttons["Clear text"].tap()
        XCTAssertEqual(group.value as? String, "Collapsed")
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
                "The official Tesserae app for quick, everyday display tasks on iPhone and iPad."
            ].exists
        )
        XCTAssertTrue(app.buttons["Enter Server Address"].exists)
        XCTAssertFalse(app.buttons["Scan Pairing QR"].exists)
    }

    func testOfflineRestoreOffersBluetoothAndOtherServers() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_OFFLINE_RESTORE"] = "1"
        app.launchEnvironment["TESSERAE_SERVER_URL"] = "http://127.0.0.1:9"
        app.launchEnvironment["TESSERAE_PAIRING_CODE"] = "123456"
        app.launch()
        XCTAssertTrue(app.buttons["offline-nearby-devices"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Server unavailable"].waitForExistence(timeout: 10))
        let recoveryShot = XCTAttachment(screenshot: app.screenshot())
        recoveryShot.name = "Offline recovery and cached displays"
        recoveryShot.lifetime = .keepAlways
        add(recoveryShot)
        app.buttons["offline-nearby-devices"].tap()
        XCTAssertTrue(app.navigationBars["Nearby Displays"].waitForExistence(timeout: 3))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Offline Bluetooth maintenance"
        shot.lifetime = .keepAlways
        add(shot)
        app.buttons["Done"].tap()
        app.buttons["choose-server"].tap()
        XCTAssertTrue(app.navigationBars["Tesserae Servers"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["No server found. Manual connection still works when discovery is unavailable."].waitForExistence(timeout: 3))
        app.buttons["Enter Server Address"].tap()
        XCTAssertTrue(app.textFields["http://host:port"].waitForExistence(timeout: 3))
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 12))
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Connect Manually"].exists)
        XCTAssertTrue(app.buttons["Connect"].isEnabled)
        app.navigationBars["Connect Manually"].buttons["Cancel"].tap()
        app.navigationBars["Tesserae Servers"].buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["choose-server"].waitForExistence(timeout: 3))
    }

    func testOnboardingOffersBluetoothWithoutPairing() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 4))
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        XCTAssertTrue(app.navigationBars["Nearby Displays"].waitForExistence(timeout: 3))
    }

    func testPicPakMaintenanceShowsRefreshSpeedsAndConfirmsSelection() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 4))
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        app.buttons["Continue"].tap()
        app.buttons["Enter 6-Digit Code"].tap()
        XCTAssertTrue(app.navigationBars["Maintenance"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["nearby-change-server"].exists)

        let speed = app.buttons["nearby-refresh-speed"]
        XCTAssertTrue(speed.waitForExistence(timeout: 3))
        XCTAssertTrue(speed.isHittable)
        XCTAssertEqual(speed.value as? String, "5 s")
        let initial = XCTAttachment(screenshot: app.screenshot())
        initial.name = "PicPak Bluetooth Refresh Speed"
        initial.lifetime = .keepAlways
        add(initial)

        speed.tap()
        XCTAssertTrue(app.buttons["5 s"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["10 s"].exists)
        XCTAssertTrue(app.buttons["Native"].exists)
        let options = XCTAttachment(screenshot: app.screenshot())
        options.name = "PicPak Refresh Speed Options"
        options.lifetime = .keepAlways
        add(options)
        app.buttons["10 s"].tap()

        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@ AND isEnabled == true", "10 s"),
            object: speed
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 3), .completed)
        XCTAssertTrue(app.navigationBars["Maintenance"].exists)
        let confirmed = XCTAttachment(screenshot: app.screenshot())
        confirmed.name = "PicPak Refresh Speed Confirmed"
        confirmed.lifetime = .keepAlways
        add(confirmed)
    }

    func testE1003MaintenanceCanChangeServerAndCancelWithoutLosingWiFiRepair() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_E1003_BLE"] = "1"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 5))
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        app.buttons["Continue"].tap()
        app.buttons["Enter 6-Digit Code"].tap()
        XCTAssertTrue(app.navigationBars["Maintenance"].waitForExistence(timeout: 4))

        let changeServer = app.buttons["nearby-change-server"]
        for _ in 0..<3 where !changeServer.isHittable { app.swipeUp() }
        changeServer.tap()
        let next = app.buttons["nearby-server-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 3))
        XCTAssertFalse(next.isEnabled)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Repair or Change Wi-Fi"].exists)
        changeServer.tap()

        let address = app.textFields["nearby-server-url"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap()
        address.typeText("https://new.example.com:8443\n")
        let pairing = app.secureTextFields["nearby-server-pairing-code"]
        pairing.tap()
        pairing.typeText("123456")
        XCTAssertTrue(next.isEnabled)
        for _ in 0..<3 where !next.isHittable { app.swipeUp() }
        let destination = XCTAttachment(screenshot: app.screenshot())
        destination.name = "E1003 Change Server Destination"
        destination.lifetime = .keepAlways
        add(destination)
        next.tap()

        XCTAssertTrue(app.staticTexts["https://new.example.com:8443"].waitForExistence(timeout: 3))
        let password = app.secureTextFields["Wi-Fi password"]
        for _ in 0..<3 where !password.isHittable { app.swipeUp() }
        password.tap()
        password.typeText("example-password")
        let save = app.buttons["Change Server"]
        for _ in 0..<3 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Server Saved"].waitForExistence(timeout: 4))
    }

    func testE1003ServerChangeChineseLargeTextAndWiFiOnlyRepair() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_E1003_BLE"] = "1"
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXXXL",
        ]
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 5))
        for _ in 0..<4 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        app.buttons["继续"].tap()
        app.buttons["输入 6 位验证码"].tap()
        let changeServer = app.buttons["nearby-change-server"]
        XCTAssertTrue(changeServer.waitForExistence(timeout: 4))
        for _ in 0..<4 where !changeServer.isHittable { app.swipeUp() }
        changeServer.tap()
        XCTAssertTrue(app.navigationBars["更改服务器"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["nearby-server-url"].label, "服务器地址")
        XCTAssertEqual(app.secureTextFields["nearby-server-pairing-code"].label, "设备配对码")
        let next = app.buttons["nearby-server-continue"]
        for _ in 0..<4 where !next.isHittable { app.swipeUp() }
        XCTAssertTrue(next.isHittable)
        XCTAssertFalse(next.isEnabled)
        let destination = XCTAttachment(screenshot: app.screenshot())
        destination.name = "E1003 Change Server Chinese Large Text"
        destination.lifetime = .keepAlways
        add(destination)
        app.buttons["取消"].tap()

        let repair = app.buttons["修复或更换 Wi-Fi"]
        for _ in 0..<4 where !repair.isHittable { app.swipeUp() }
        repair.tap()
        XCTAssertFalse(app.buttons["编辑服务器"].exists)
        app.buttons["Home Wi-Fi"].tap()
        let password = app.secureTextFields["Wi-Fi 密码"]
        for _ in 0..<4 where !password.isHittable { app.swipeUp() }
        password.tap()
        password.typeText("example-password")
        let save = app.buttons["连接显示屏"]
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Display Connected"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["服务器已保存"].exists)
    }

    func testPicPakScreenModeSavesAndAuthorizesThisPhone() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 5))
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        app.buttons["Continue"].tap()
        app.buttons["Enter 6-Digit Code"].tap()
        let mode = app.buttons["nearby-screen-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 4))
        XCTAssertEqual(mode.value as? String, "Automatic (Wi-Fi)")
        mode.tap()
        app.buttons["Manual (Bluetooth)"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Manual (Bluetooth)"), object: mode
        )], timeout: 3), .completed)
        XCTAssertFalse(app.buttons["Allow This Device"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "PicPak Manual Bluetooth Mode"; shot.lifetime = .keepAlways; add(shot)
        mode.tap()
        app.buttons["Automatic (Wi-Fi)"].tap()
        XCTAssertEqual(mode.value as? String, "Automatic (Wi-Fi)")
    }

    func testPicPakPhotoSessionOpensSendSheetAndReceivesImage() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_PHOTO"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_CONNECTION_DELAY_MS"] = "6000"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 5))
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        let invitation = app.staticTexts["Ready to Receive"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 4))
        XCTAssertFalse(app.navigationBars["Send to PicPak"].exists)
        XCTAssertFalse(app.buttons["ble-send-photo"].exists)
        XCTAssertGreaterThan(invitation.frame.minY, app.frame.height / 2)
        let invitationShot = XCTAttachment(screenshot: app.screenshot())
        invitationShot.name = "PicPak Photo Invitation"; invitationShot.lifetime = .keepAlways; add(invitationShot)
        app.buttons["ble-photo-start"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["ble-photo-status"].waitForExistence(timeout: 3))
        let connectingShot = XCTAttachment(screenshot: app.screenshot())
        connectingShot.name = "PicPak Centered Connection"; connectingShot.lifetime = .keepAlways; add(connectingShot)
        XCTAssertTrue(app.navigationBars["Send to PicPak"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Maintenance"].exists)
        XCTAssertTrue(app.buttons["ble-change-photo"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts["Image Fit"].exists)
        let deviceInfo = app.buttons["ble-photo-device-info"]
        XCTAssertTrue(deviceInfo.exists)
        XCTAssertTrue(app.staticTexts["Battery voltage: 3.90 V"].exists)
        XCTAssertTrue(app.staticTexts["Refresh speed: 5 s"].exists)
        deviceInfo.tap()
        let infoShot = XCTAttachment(screenshot: app.screenshot())
        infoShot.name = "PicPak Photo Device Info"; infoShot.lifetime = .keepAlways; add(infoShot)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Manual (Bluetooth)"))
            .firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "0.9.3"))
            .firstMatch.exists)
        deviceInfo.tap()
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "PicPak Bluetooth Photo Sheet"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["ble-send-photo"].tap()
        XCTAssertTrue(app.staticTexts["Photo Sent"].waitForExistence(timeout: 12))
        let completionShot = XCTAttachment(screenshot: app.screenshot())
        completionShot.name = "PicPak Compact Completion"; completionShot.lifetime = .keepAlways; add(completionShot)
    }

    func testPicPakPhotoDiscoveryWaitsForSendAndRespondsToShortDrag() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_PHOTO"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_AUTO_DISCOVERY"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["ble-photo-start"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["ble-send-photo"].exists)
        app.buttons["Close"].tap()
        XCTAssertFalse(app.buttons["ble-photo-start"].exists)

        // Dismissing an invitation still allows a deliberate selection from Nearby Displays.
        let nearby = app.buttons["onboarding-nearby-devices"]
        for _ in 0..<3 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        XCTAssertTrue(app.buttons["ble-photo-start"].waitForExistence(timeout: 3))
        app.buttons["ble-photo-start"].tap()
        let canvas = app.descendants(matching: .any)["ble-photo-image"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 4))
        let originalFrame = canvas.frame
        let reset = app.buttons["send-framing-reset"]
        XCTAssertFalse(reset.isEnabled)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 8, dy: 0)))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: reset)
        waitForExpectations(timeout: 4)
        XCTAssertEqual(canvas.frame.minY, originalFrame.minY, accuracy: 1)
        XCTAssertEqual(canvas.frame.height, originalFrame.height, accuracy: 1)
        // The shared editor hides its controls briefly while finishing a crop gesture.
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: reset)
        waitForExpectations(timeout: 4)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "PicPak Short Crop Drag"; shot.lifetime = .keepAlways; add(shot)
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        app.segmentedControls.buttons["Fit"].tap()
        XCTAssertFalse(app.buttons["send-framing-reset"].exists)
        app.segmentedControls.buttons["Fill"].tap()
        XCTAssertTrue(app.buttons["send-framing-reset"].exists)
    }

    func testDemoGalleryBrowsesFoldersAndHandsPhotoToSend() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_AUTO_FRAMING"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_GALLERY_GRID_MODE"] = "square"
        app.launchEnvironment["TESSERAE_UI_TEST_GALLERY_GRID_COLUMNS"] = "3"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let galleryTab = app.tabBars.firstMatch.buttons["Library"]
        XCTAssertTrue(galleryTab.waitForExistence(timeout: 3))
        galleryTab.tap()

        let family = app.buttons["gallery-folder-folder_family"]
        let archive = app.buttons["gallery-folder-folder_archive"]
        XCTAssertTrue(family.waitForExistence(timeout: 3))
        XCTAssertTrue(archive.exists)
        XCTAssertTrue(app.buttons["gallery-create-folder"].exists)

        let foldersScreenshot = XCTAttachment(screenshot: app.screenshot())
        foldersScreenshot.name = "Gallery Folders"
        foldersScreenshot.lifetime = .keepAlways
        add(foldersScreenshot)

        family.tap()
        let image = app.buttons["gallery-image-image_family_01"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["gallery-add-photos"].exists)
        XCTAssertTrue(app.buttons["gallery-grid-options"].exists)

        let squareFrame = image.frame
        XCTAssertEqual(squareFrame.width, squareFrame.height, accuracy: 1)

        let gridScreenshot = XCTAttachment(screenshot: app.screenshot())
        gridScreenshot.name = "Gallery Square Photo Grid"
        gridScreenshot.lifetime = .keepAlways
        add(gridScreenshot)

        let photoGrid = app.descendants(matching: .any)
            .matching(identifier: "gallery-photo-grid").firstMatch
        XCTAssertTrue(photoGrid.exists)
        let gridFrame = photoGrid.frame
        let folderScroll = app.scrollViews["gallery-folder-scroll"]
        XCTAssertTrue(folderScroll.exists)
        folderScroll.pinch(withScale: 2, velocity: 1)
        let gridZoomed = XCTNSPredicateExpectation(
            predicate: NSPredicate { evaluated, _ in
                guard let element = evaluated as? XCUIElement else { return false }
                return element.frame.height > gridFrame.height * 1.5
            },
            object: photoGrid
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [gridZoomed], timeout: 2),
            .completed
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "gallery-photo-page-image_family_01"
            ].exists
        )

        app.buttons["gallery-grid-options"].tap()
        let aspectRatioGrid = app.buttons["Aspect Ratio Grid"]
        XCTAssertTrue(aspectRatioGrid.waitForExistence(timeout: 2))
        aspectRatioGrid.tap()

        let aspectFrameExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { evaluated, _ in
                guard let element = evaluated as? XCUIElement else { return false }
                let frame = element.frame
                guard frame.width > 0, frame.height > 0 else { return false }
                return abs(frame.width / frame.height - 0.75) < 0.05
            },
            object: image
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [aspectFrameExpectation], timeout: 2),
            .completed
        )
        XCTAssertTrue(image.isHittable)

        let aspectScreenshot = XCTAttachment(screenshot: app.screenshot())
        aspectScreenshot.name = "Gallery Aspect Ratio Grid"
        aspectScreenshot.lifetime = .keepAlways
        add(aspectScreenshot)

        image.tap()

        let firstPage = app.descendants(matching: .any)[
            "gallery-photo-page-image_family_01"
        ]
        XCTAssertTrue(firstPage.waitForExistence(timeout: 3))
        XCTAssertTrue(
            app.staticTexts["gallery-photo-position-image_family_01"].exists
        )

        firstPage.swipeLeft()
        let secondPage = app.descendants(matching: .any)[
            "gallery-photo-page-image_family_02"
        ]
        XCTAssertTrue(secondPage.waitForExistence(timeout: 3))
        XCTAssertTrue(secondPage.isHittable)

        let previewScreenshot = XCTAttachment(screenshot: app.screenshot())
        previewScreenshot.name = "Gallery Paged Photo Preview"
        previewScreenshot.lifetime = .keepAlways
        add(previewScreenshot)

        let secondPreview = app.buttons[
            "gallery-image-preview-image_family_02"
        ]
        XCTAssertTrue(secondPreview.waitForExistence(timeout: 3))
        secondPreview.tap()

        let immersive = app.descendants(matching: .any)["gallery-immersive-view"]
        XCTAssertTrue(immersive.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["gallery-immersive-close"].exists)
        XCTAssertFalse(app.staticTexts["gallery-immersive-position"].exists)
        let secondImmersivePhoto = app.descendants(matching: .any)[
            "gallery-immersive-photo-image_family_02"
        ]
        XCTAssertTrue(secondImmersivePhoto.waitForExistence(timeout: 3))
        secondImmersivePhoto.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(secondImmersivePhoto.value as? String, "1.00×")
        XCTAssertTrue(secondImmersivePhoto.isHittable)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "gallery-immersive-photo-image_family_03"
            ].isHittable
        )
        secondImmersivePhoto.pinch(withScale: 0.5, velocity: -1)
        if secondImmersivePhoto.value as? String != "1.00×" {
            secondImmersivePhoto.doubleTap()
        }
        let zoomReset = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1.00×"),
            object: secondImmersivePhoto
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [zoomReset], timeout: 2),
            .completed
        )

        secondImmersivePhoto.swipeLeft()
        let thirdImmersivePhoto = app.descendants(matching: .any)[
            "gallery-immersive-photo-image_family_03"
        ]
        XCTAssertTrue(thirdImmersivePhoto.waitForExistence(timeout: 3))
        XCTAssertTrue(thirdImmersivePhoto.isHittable)
        let renderedPhoto = app.images["gallery-immersive-photo-image_family_03"]
        XCTAssertTrue(renderedPhoto.waitForExistence(timeout: 3))
        XCTAssertEqual(renderedPhoto.label, "Photo")

        let immersiveScreenshot = XCTAttachment(screenshot: app.screenshot())
        immersiveScreenshot.name = "Gallery Immersive Photo"
        immersiveScreenshot.lifetime = .keepAlways
        add(immersiveScreenshot)

        immersive.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(
                forDuration: 0.05,
                thenDragTo: immersive.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)
                )
            )
        let immersiveDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: immersive
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [immersiveDismissed], timeout: 2),
            .completed
        )

        let sendImage = app.buttons["gallery-send-image"]
        XCTAssertTrue(sendImage.waitForExistence(timeout: 3))
        sendImage.tap()
        XCTAssertTrue(
            app.buttons["send-change-photo"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.buttons["Send to Displays"].exists)
        let framingAuto = app.buttons["send-auto-framing"]
        XCTAssertTrue(framingAuto.waitForExistence(timeout: 4))
        XCTAssertEqual(framingAuto.value as? String, "Adjusted")
        XCTAssertEqual(app.staticTexts["send-framing-zoom"].label, "2.0×")
    }

    func testDemoGalleryFolderLoadingLabelStaysReadable() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "3000"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let galleryTab = app.tabBars.firstMatch.buttons
            .matching(identifier: "Library").firstMatch
        XCTAssertTrue(galleryTab.waitForExistence(timeout: 8))
        galleryTab.tap()

        let family = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(family.waitForExistence(timeout: 8))
        family.tap()

        let loadingLabel = app.staticTexts["Loading Photos…"]
        XCTAssertTrue(loadingLabel.waitForExistence(timeout: 1))
        XCTAssertGreaterThan(loadingLabel.frame.width, 80)
        XCTAssertLessThan(loadingLabel.frame.height, 40)
    }

    func testDemoGalleryUploadStartsCollapsedAndOpensDetailsOnTap() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_GALLERY_UPLOAD_CAPSULE"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let capsule = app.buttons["gallery-upload-capsule"]
        XCTAssertTrue(capsule.waitForExistence(timeout: 3))
        XCTAssertEqual(capsule.label, "Uploading 2 of 5")
        XCTAssertFalse(app.navigationBars["Upload Details"].exists)
        let sendAction = app.buttons["root-send-action"]
        XCTAssertTrue(sendAction.exists)
        XCTAssertLessThan(capsule.frame.midY, app.frame.height * 0.2)
        XCTAssertGreaterThan(sendAction.frame.midX, app.frame.midX)
        XCTAssertTrue(sendAction.isHittable)
        XCTAssertFalse(capsule.frame.intersects(sendAction.frame))

        let capsuleScreenshot = XCTAttachment(screenshot: app.screenshot())
        capsuleScreenshot.name = "Gallery Upload Capsule"
        capsuleScreenshot.lifetime = .keepAlways
        add(capsuleScreenshot)

        capsule.tap()

        XCTAssertTrue(
            app.navigationBars["Upload Details"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["family"].exists)
        XCTAssertTrue(app.staticTexts["2 of 5 finished"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(capsule.waitForExistence(timeout: 2))
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
        XCTAssertEqual(historyStatus.label, "Ready for Display")
        XCTAssertEqual(
            app.descendants(matching: .any)[
                "history-status-history-demo-dashboard"
            ].label,
            "Action Sent"
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

    func testRootToolbarsKeepSettingsAndContextActionsConsistent() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let settings = app.buttons["root-settings"]

        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(settings.frame.maxX, app.frame.maxX)
        XCTAssertFalse(app.buttons["dashboard-layout-toggle"].exists)
        XCTAssertFalse(app.buttons["clear-local-activity"].exists)

        app.buttons["Dashboards"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(settings.frame.maxX, app.frame.maxX)
        XCTAssertTrue(
            app.buttons["dashboard-layout-toggle"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertGreaterThan(
            settings.frame.minX,
            app.buttons["dashboard-layout-toggle"].frame.maxX
        )
        XCTAssertFalse(app.buttons["clear-local-activity"].exists)
        let dashboardsToolbarScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        dashboardsToolbarScreenshot.name = "Dashboards Root Toolbar"
        dashboardsToolbarScreenshot.lifetime = .keepAlways
        add(dashboardsToolbarScreenshot)

        XCTAssertFalse(app.tabBars.buttons["Send"].exists)
        app.buttons["root-send-action"].tap()
        let sendSettingsQuery = app.buttons.matching(
            identifier: "root-settings"
        )
        XCTAssertTrue(app.buttons["root-send-close"].waitForExistence(timeout: 2))
        XCTAssertFalse(sendSettingsQuery.allElementsBoundByIndex.contains { $0.isHittable })
        XCTAssertFalse(app.buttons["dashboard-layout-toggle"].isHittable)
        XCTAssertFalse(app.buttons["clear-local-activity"].isHittable)

        let sendScreenshot = XCTAttachment(screenshot: app.screenshot())
        sendScreenshot.name = "Send without Settings"
        sendScreenshot.lifetime = .keepAlways
        add(sendScreenshot)

        app.buttons["root-send-close"].tap()
        app.buttons["Activity"].firstMatch.tap()
        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(settings.frame.maxX, app.frame.maxX)
        XCTAssertFalse(app.buttons["clear-local-activity"].exists)
        XCTAssertFalse(app.buttons["dashboard-layout-toggle"].exists)
        let activityToolbarScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        activityToolbarScreenshot.name = "Activity Root Toolbar"
        activityToolbarScreenshot.lifetime = .keepAlways
        add(activityToolbarScreenshot)
    }

    func testDashboardGroupCollapseAndExpand() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.buttons["Dashboards"].firstMatch.tap()

        let layoutToggle = app.buttons["dashboard-layout-toggle"]
        XCTAssertTrue(layoutToggle.waitForExistence(timeout: 2))
        if layoutToggle.label == "Use Card View" {
            layoutToggle.tap()
        }

        let group = app.buttons[
            "dashboard-section-toggle-display-picpak-kitchen"
        ]
        let pantryTitle = app.staticTexts[
            "dashboard-title-pantry-display-picpak-kitchen"
        ]
        let pantryPushButton = app.buttons[
            "dashboard-push-pantry-display-picpak-kitchen"
        ]
        for _ in 0..<4 where !pantryTitle.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(group.waitForExistence(timeout: 2))
        XCTAssertTrue(pantryTitle.isHittable)
        XCTAssertTrue(pantryPushButton.isHittable)

        let pantryPreviewButton = app.buttons[
            "dashboard-preview-button-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(pantryPreviewButton.waitForExistence(timeout: 2))

        layoutToggle.tap()
        XCTAssertEqual(layoutToggle.label, "Use Card View")
        XCTAssertFalse(pantryPreviewButton.exists)
        XCTAssertFalse(pantryPushButton.exists)
        XCTAssertFalse(app.staticTexts["1200 × 1600"].exists)
        XCTAssertFalse(app.staticTexts["800 × 480"].exists)
        let pantryListRow = app.buttons[
            "dashboard-row-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(pantryListRow.isHittable)
        let listLayoutScreenshot = XCTAttachment(screenshot: app.screenshot())
        listLayoutScreenshot.name = "Dashboard List Layout"
        listLayoutScreenshot.lifetime = .keepAlways
        add(listLayoutScreenshot)

        pantryListRow.tap()
        XCTAssertTrue(
            app.staticTexts["dashboard-push-sheet-title"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["dashboard-push-preview-pantry"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["Cancel"].tap()
        XCTAssertTrue(layoutToggle.waitForExistence(timeout: 2))

        layoutToggle.tap()
        XCTAssertEqual(layoutToggle.label, "Use List View")
        XCTAssertTrue(pantryPreviewButton.waitForExistence(timeout: 2))
        for _ in 0..<4 where !pantryPushButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(pantryPushButton.isHittable)
        let cardLayoutScreenshot = XCTAttachment(screenshot: app.screenshot())
        cardLayoutScreenshot.name = "Dashboard Card Layout"
        cardLayoutScreenshot.lifetime = .keepAlways
        add(cardLayoutScreenshot)

        group.tap()
        XCTAssertEqual(group.value as? String, "Collapsed")
        XCTAssertFalse(
            app.staticTexts["dashboard-push-sheet-title"].exists
        )

        group.tap()
        XCTAssertEqual(group.value as? String, "Expanded")
        for _ in 0..<4 where !pantryPushButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(pantryPushButton.isHittable)
    }

    func testDemoJourneyAcrossMainTabs() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()

        XCTAssertTrue(app.buttons["Displays"].firstMatch.waitForExistence(timeout: 3))
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
        let displaysBack = app.navigationBars["Kitchen"].buttons["Displays"]
        XCTAssertTrue(displaysBack.exists || kitchenCard.isHittable)
        XCTAssertFalse(app.navigationBars["Kitchen"].buttons["Close"].exists)
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "display-pending-status-picpak-kitchen"
            ].exists
        )
        XCTAssertFalse(app.staticTexts["Device ID"].exists)
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
        if displaysBack.exists { displaysBack.tap() }
        XCTAssertTrue(
            app.staticTexts["Kitchen"].waitForExistence(timeout: 2)
        )

        let deskPreview = app.descendants(matching: .any)["display-preview-e1004-desk"]
        for _ in 0..<4 where !deskPreview.exists {
            app.swipeUp()
        }
        assertPreview(deskPreview, hasAspectRatio: 1_200.0 / 1_600.0)

        app.buttons["Dashboards"].firstMatch.tap()
        let dashboardLayoutToggle = app.buttons["dashboard-layout-toggle"]
        XCTAssertTrue(dashboardLayoutToggle.waitForExistence(timeout: 2))
        if dashboardLayoutToggle.label == "Use Card View" {
            dashboardLayoutToggle.tap()
        }
        let kitchenDashboardGroup = app.buttons[
            "dashboard-section-toggle-display-picpak-kitchen"
        ]
        XCTAssertTrue(kitchenDashboardGroup.waitForExistence(timeout: 2))
        if kitchenDashboardGroup.value as? String == "Collapsed" {
            kitchenDashboardGroup.tap()
        }
        XCTAssertEqual(kitchenDashboardGroup.value as? String, "Expanded")
        let pantryTitle = app.staticTexts[
            "dashboard-title-pantry-display-picpak-kitchen"
        ]
        let collapsedPantryPushButton = app.buttons[
            "dashboard-push-pantry-display-picpak-kitchen"
        ]
        for _ in 0..<4 where !pantryTitle.exists {
            app.swipeUp()
        }
        XCTAssertTrue(pantryTitle.waitForExistence(timeout: 2))
        kitchenDashboardGroup.tap()
        XCTAssertEqual(kitchenDashboardGroup.value as? String, "Collapsed")
        XCTAssertFalse(
            app.staticTexts["dashboard-push-sheet-title"].exists
        )
        kitchenDashboardGroup.tap()
        XCTAssertEqual(kitchenDashboardGroup.value as? String, "Expanded")
        for _ in 0..<4 where !collapsedPantryPushButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(collapsedPantryPushButton.isHittable)
        let dashboardPreviewButton = app.buttons[
            "dashboard-preview-button-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(dashboardPreviewButton.waitForExistence(timeout: 2))
        let previewLoaded = NSPredicate(format: "isEnabled == true")
        expectation(
            for: previewLoaded,
            evaluatedWith: dashboardPreviewButton
        )
        waitForExpectations(timeout: 2)
        XCTAssertEqual(
            dashboardPreviewButton.value as? String,
            "Collapsed"
        )
        dashboardPreviewButton.tap()
        XCTAssertEqual(
            dashboardPreviewButton.value as? String,
            "Expanded"
        )
        let expandedDashboardPreview = app.descendants(matching: .any)[
            "dashboard-preview-expanded-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(
            expandedDashboardPreview.waitForExistence(timeout: 2)
        )
        XCTAssertGreaterThan(expandedDashboardPreview.frame.height, 0)
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

        let pantryPushButton = app.buttons[
            "dashboard-push-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(pantryPushButton.exists)
        pantryPushButton.tap()
        let pushDashboardTitle = app.staticTexts[
            "dashboard-push-sheet-title"
        ]
        XCTAssertTrue(pushDashboardTitle.waitForExistence(timeout: 2))
        XCTAssertTrue(pushDashboardTitle.isHittable)
        XCTAssertFalse(
            app.staticTexts[
                "Choose one or more displays already bound to this dashboard."
            ].exists
        )
        let pantryPushPreview = app.descendants(matching: .any)[
            "dashboard-push-preview-pantry"
        ]
        XCTAssertTrue(pantryPushPreview.exists)
        let pantryPushCaption = app.staticTexts[
            "dashboard-push-preview-caption-pantry"
        ]
        XCTAssertTrue(pantryPushCaption.waitForExistence(timeout: 2))
        XCTAssertEqual(pantryPushCaption.label, "Pantry · 800 × 480")
        XCTAssertGreaterThan(
            pantryPushCaption.frame.minY,
            pantryPushPreview.frame.maxY,
            "Dashboard name and resolution should sit below the preview."
        )
        XCTAssertFalse(app.staticTexts["Bound Displays"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "dashboard-push-device-e1004-desk"
            ].exists
        )
        XCTAssertFalse(
            app.descendants(matching: .any)[
                "dashboard-push-single-target-picpak-kitchen"
            ].exists
        )
        let pushToSelectedDisplays = app.buttons[
            "Push to Kitchen"
        ]
        XCTAssertTrue(pushToSelectedDisplays.isEnabled)
        XCTAssertLessThan(
            pushToSelectedDisplays.frame.maxY,
            app.frame.maxY,
            "The dashboard detail must keep its primary action fully visible."
        )
        let dashboardPushScreenshot = XCTAttachment(
            screenshot: app.screenshot()
        )
        dashboardPushScreenshot.name = "Single Display Dashboard Push Sheet"
        dashboardPushScreenshot.lifetime = .keepAlways
        add(dashboardPushScreenshot)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(pantryPushButton.waitForExistence(timeout: 2))

        let sharedPushButton = app.buttons[
            "dashboard-push-photo-frame-shared"
        ]
        for _ in 0..<5 where !sharedPushButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(sharedPushButton.waitForExistence(timeout: 2))
        sharedPushButton.tap()
        XCTAssertTrue(app.staticTexts["Bound Displays"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "dashboard-push-device-picpak-kitchen"
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "dashboard-push-device-e1004-desk"
            ].exists
        )
        XCTAssertTrue(app.buttons["Push to 2 Displays"].isEnabled)
        let sharedSheetTitleY = pushDashboardTitle.frame.minY
        let deskSelection = app.buttons[
            "dashboard-push-device-e1004-desk"
        ]
        XCTAssertTrue(deskSelection.isHittable)
        deskSelection.tap()
        XCTAssertTrue(app.buttons["Push to Kitchen"].waitForExistence(timeout: 2))
        XCTAssertEqual(
            pushDashboardTitle.frame.minY,
            sharedSheetTitleY,
            accuracy: 1,
            "Changing a display selection must not resize or jolt the sheet."
        )
        deskSelection.tap()
        XCTAssertTrue(
            app.buttons["Push to 2 Displays"].waitForExistence(timeout: 2)
        )
        app.buttons["Cancel"].tap()

        let dashboardScreenshot = XCTAttachment(screenshot: app.screenshot())
        dashboardScreenshot.name = "Dashboard Compact Previews"
        dashboardScreenshot.lifetime = .keepAlways
        add(dashboardScreenshot)

        app.buttons["root-send-action"].tap()
        let samplePhoto = app.buttons["Use Sample"]
        scrollToButton(samplePhoto, app: app)
        samplePhoto.tap()
        let sendButton = app.buttons["Send to Displays"]
        scrollToButton(sendButton, app: app)
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let sentBanner = app.descendants(matching: .any)[
            "send-success-banner"
        ]
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
        app.buttons["Activity"].firstMatch.tap()
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
        XCTAssertEqual(historyStatus.label, "Ready for Display")
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

        app.buttons["root-settings"].tap()
        XCTAssertTrue(
            app.staticTexts["Data & Privacy"].waitForExistence(timeout: 2)
        )
        let clearLocalActivityButton = app.buttons["clear-local-activity"]
        XCTAssertTrue(clearLocalActivityButton.waitForExistence(timeout: 2))
        XCTAssertTrue(clearLocalActivityButton.isHittable)
        clearLocalActivityButton.tap()

        let confirmation = app.alerts["Clear Local Activity?"]
        XCTAssertTrue(confirmation.waitForExistence(timeout: 2))
        confirmation.buttons["Clear Local Activity"].tap()
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

    func testDisplayDetailsOpenInNavigation() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
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
        XCTAssertFalse(detailNavigation.buttons["Close"].exists)
        XCTAssertTrue(detailNavigation.buttons["Displays"].exists)
        XCTAssertTrue(app.staticTexts["Current Screen"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "display-screen-page-indicator-picpak-kitchen"
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Connection & Power"].exists)
        XCTAssertTrue(app.staticTexts["Battery"].exists)
        XCTAssertFalse(app.staticTexts["Device ID"].exists)
        XCTAssertFalse(app.staticTexts["Device Type"].exists)
        XCTAssertFalse(app.staticTexts["Colour Gamut"].exists)

        let overviewScreenshot = XCTAttachment(screenshot: app.screenshot())
        overviewScreenshot.name = "Display Details Overview"
        overviewScreenshot.lifetime = .keepAlways
        add(overviewScreenshot)

        let details = app.buttons["display-device-details-picpak-kitchen"]
        XCTAssertTrue(details.exists)
        for _ in 0..<4 where !details.isHittable { app.swipeUp() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertTrue(app.staticTexts["Device ID"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Manufacturer"].exists)
        XCTAssertTrue(app.staticTexts["Model"].exists)
        XCTAssertTrue(app.staticTexts["Firmware"].exists)
        XCTAssertTrue(app.staticTexts["Device Type"].exists)
        XCTAssertTrue(app.staticTexts["800 × 480"].exists)
        XCTAssertTrue(app.staticTexts["Spectra 6 · 6-color"].exists)
        XCTAssertFalse(app.staticTexts["Waveshare E6"].exists)
        for _ in 0..<3 where !app.staticTexts["Colour Gamut"].isHittable {
            app.swipeUp()
        }

        let hardwareScreenshot = XCTAttachment(screenshot: app.screenshot())
        hardwareScreenshot.name = "Display Details Expanded"
        hardwareScreenshot.lifetime = .keepAlways
        add(hardwareScreenshot)

        for _ in 0..<4 where !details.isHittable { app.swipeDown() }
        XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertFalse(app.staticTexts["Device ID"].exists)
        XCTAssertFalse(app.staticTexts["Colour Gamut"].exists)

        detailNavigation.buttons["Displays"].tap()
        XCTAssertTrue(kitchenCard.waitForExistence(timeout: 2))
    }

    func testDisplayCardsReorderWithLongPressDrag() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let kitchen = app.buttons["display-card-picpak-kitchen"]
        let desk = app.buttons["display-card-e1004-desk"]
        XCTAssertTrue(kitchen.waitForExistence(timeout: 3))
        XCTAssertTrue(desk.waitForExistence(timeout: 3))
        XCTAssertFalse(kitchen.label.isEmpty)
        XCTAssertFalse(desk.label.isEmpty)
        XCTAssertTrue((kitchen.value as? String)?.hasPrefix("Display ") == true)
        XCTAssertTrue((desk.value as? String)?.hasPrefix("Display ") == true)

        for _ in 0..<3 where !kitchen.isHittable || !desk.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(kitchen.isHittable)
        XCTAssertTrue(desk.isHittable)

        let upper = kitchen.frame.minY < desk.frame.minY ? kitchen : desk
        let lower = kitchen.frame.minY < desk.frame.minY ? desk : kitchen
        let cardWidth = upper.frame.width

        lower.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
        ).press(
            forDuration: 0.45,
            thenDragTo: upper.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)
            )
        )

        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                lower.frame.minY < upper.frame.minY
            },
            object: nil
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [reordered], timeout: 2),
            .completed
        )
        XCTAssertEqual(lower.frame.width, cardWidth, accuracy: 1)
        XCTAssertEqual(lower.frame.minX, upper.frame.minX, accuracy: 1)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Reordered Display Cards"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testDemoSendSupportsLinkActions() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "1000"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.buttons["root-send-action"].tap()

        XCTAssertTrue(app.buttons["Link"].waitForExistence(timeout: 2))
        app.buttons["Link"].tap()
        XCTAssertTrue(app.buttons["Image URL"].exists)
        XCTAssertTrue(app.buttons["Webpage Snapshot"].exists)

        let linkField = app.textFields["send-link-url"]
        XCTAssertTrue(linkField.exists)
        linkField.tap()
        linkField.typeText("https://example.com/news\n")

        let sendButton = app.buttons["Send to Displays"]
        scrollToButton(sendButton, app: app)
        XCTAssertTrue(sendButton.isEnabled)
        sendButton.tap()

        let progressCapsule = app.descendants(matching: .any)[
            "send-progress-capsule"
        ]
        XCTAssertTrue(progressCapsule.waitForExistence(timeout: 2))
        XCTAssertFalse(
            sendButton.descendants(matching: .activityIndicator).firstMatch.exists
        )

        let sentBanner = app.descendants(matching: .any)[
            "send-success-banner"
        ]
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 10))
        XCTAssertTrue(
            sentBanner.label.contains("Sent to Displays")
        )

        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
        let transientMessageDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sentBanner
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [transientMessageDismissed], timeout: 4),
            .completed
        )
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
        XCTAssertTrue(historyCard.waitForExistence(timeout: 15))
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
        app.launchArguments += ["-dashboardLayoutMode", "cards"]
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        app.buttons["Dashboards"].firstMatch.tap()

        let photoFrame = app.staticTexts["dashboard-title-photo-frame-display-picpak-kitchen"]
        let pantry = app.staticTexts["dashboard-title-pantry-display-picpak-kitchen"]
        let list = app.scrollViews["dashboard-list"]
        for _ in 0..<5 where !photoFrame.isHittable || !pantry.isHittable {
            list.swipeUp()
        }
        XCTAssertTrue(photoFrame.isHittable)
        XCTAssertTrue(pantry.isHittable)
        func precedes(_ first: XCUIElement, _ second: XCUIElement) -> Bool {
            let a = first.frame
            let b = second.frame
            return abs(a.minY - b.minY) < 1 ? a.minX < b.minX : a.minY < b.minY
        }
        let first = precedes(photoFrame, pantry) ? photoFrame : pantry
        let second = precedes(photoFrame, pantry) ? pantry : photoFrame
        second.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(
            forDuration: 0.45,
            thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        )
        let reordered = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in precedes(second, first) }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed)
    }

    private func scrollToButton(_ button: XCUIElement, app: XCUIApplication) {
        let identifier = button.identifier.isEmpty ? button.label : button.identifier
        let region = app.scrollViews.containing(.button, identifier: identifier).firstMatch
        for _ in 0..<6 where !button.isHittable {
            let start = region.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.8))
            let end = region.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.15))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(button.isHittable)
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

    func testChineseAccessibilityScreensInDarkMode() {
        exerciseReadabilityScreens(app: readabilityApp(), largeText: true, prefix: "Chinese AX5 dark")
    }

    func testAccessibilitySemanticsAndHitRegions() throws {
        let app = readabilityApp(largeText: false)
        app.launch()
        func audit(_ name: String) throws {
            readabilityAttachment(app, "Accessibility audit \(name)")
            // Font/contrast audits flag native glass, search fields and hidden icon
            // glyphs. Cover those separately with AX5 screenshots and VoiceOver.
            try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait])
        }
        XCTAssertTrue(app.buttons["使用演示数据体验"].waitForExistence(timeout: 5))
        try audit("onboarding")
        app.buttons["使用演示数据体验"].tap()
        XCTAssertTrue(app.buttons["root-settings"].waitForExistence(timeout: 5))
        try audit("displays")
        app.buttons["root-settings"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        try audit("settings")
        app.buttons["完成"].tap()
        app.tabBars.firstMatch.buttons["图库"].tap()
        XCTAssertTrue(app.buttons["gallery-folder-folder_family"].waitForExistence(timeout: 4))
        try audit("gallery")
        app.tabBars.firstMatch.buttons["显示屏"].tap()
        app.buttons["manage-lineups"].tap()
        XCTAssertTrue(app.buttons["lineup-card-kitchen-deck"].waitForExistence(timeout: 4))
        try audit("lineups")
        app.buttons["lineup-card-kitchen-deck"].tap()
        XCTAssertTrue(app.switches["lineup-enabled-on"].waitForExistence(timeout: 4))
        try audit("lineup detail")
        app.buttons["root-send-action"].tap()
        XCTAssertTrue(app.buttons["root-send-close"].waitForExistence(timeout: 4))
        try audit("send")
    }

    func testVoiceOverPrimaryFlow() throws {
#if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver service requires iOS 27.") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        restoreVoiceOverEnabled = voiceOver.isEnabled
        try voiceOver.disable()
        let app = readabilityApp(largeText: false)
        app.launch()
        XCTAssertTrue(app.buttons["使用演示数据体验"].waitForExistence(timeout: 5))
        app.buttons["使用演示数据体验"].tap()
        XCTAssertTrue(app.buttons["root-settings"].waitForExistence(timeout: 5))
        try voiceOver.enable()
        var speech = [try voiceOver.currentSpeech().utterance]
        for _ in 0..<16 {
            let next = try voiceOver.moveForward().utterance
            print("VOICEOVER_NEXT", next)
            speech.append(next)
            if next.contains("活动") && next.contains("4 of 4") { break }
        }
        XCTAssertEqual(speech.filter { $0.contains("Desk") }.count, 1, speech.joined(separator: "\n"))
        XCTAssertEqual(speech.filter { $0.contains("Kitchen") }.count, 1, speech.joined(separator: "\n"))
        XCTAssertTrue(speech.contains { $0.contains("管理播放队列") })
        XCTAssertTrue(speech.contains { $0.contains("显示屏") && $0.contains("selected") })
        XCTAssertFalse(speech.joined().unicodeScalars.contains { (0xE000...0xF8FF).contains($0.value) })
        var settingsFocused = false
        for _ in 0..<16 {
            let previous = try voiceOver.moveBackward().utterance
            if previous.contains("设置") {
                settingsFocused = true
                break
            }
        }
        XCTAssertTrue(settingsFocused)
        app.buttons["root-settings"].doubleTap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 4))
        let modalSpeech = try voiceOver.currentSpeech().utterance
        print("VOICEOVER_MODAL_FOCUS", modalSpeech)
        XCTAssertFalse(modalSpeech.contains("Kitchen") || modalSpeech.contains("Desk"))
#else
        throw XCTSkip("VoiceOver service requires the iOS 27 SDK.")
#endif
    }

    func testVoiceOverGalleryPhotoSemantics() throws {
#if compiler(>=6.4)
        guard #available(iOS 27.0, *) else { throw XCTSkip("VoiceOver service requires iOS 27.") }
        let voiceOver = XCUIDevice.shared.voiceOverService
        restoreVoiceOverEnabled = voiceOver.isEnabled
        try voiceOver.disable()
        let app = readabilityApp(largeText: false)
        app.launchEnvironment["TESSERAE_UI_TEST_GALLERY_GRID_MODE"] = "square"
        app.launchEnvironment["TESSERAE_UI_TEST_GALLERY_GRID_COLUMNS"] = "3"
        app.launch()
        XCTAssertTrue(app.buttons["使用演示数据体验"].waitForExistence(timeout: 5))
        app.buttons["使用演示数据体验"].tap()
        XCTAssertTrue(app.buttons["root-settings"].waitForExistence(timeout: 5))
        // The native tab bar briefly exposes its outgoing label and final button
        // during the onboarding transition. Wait for an unambiguous target.
        let galleryTabs = app.tabBars.firstMatch.buttons.matching(identifier: "图库")
        let settledTabs = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "count == 1"), object: galleryTabs
        )
        XCTAssertEqual(XCTWaiter.wait(for: [settledTabs], timeout: 5), .completed)
        galleryTabs.element.tap()
        let family = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(family.waitForExistence(timeout: 4))
        family.tap()
        let thumbnail = app.buttons["gallery-image-image_family_01"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 4))
        thumbnail.tap()
        let preview = app.buttons["gallery-image-preview-image_family_01"]
        XCTAssertTrue(preview.waitForExistence(timeout: 4))
        preview.tap()
        let photo = app.descendants(matching: .any)["gallery-immersive-photo-image_family_01"]
        XCTAssertTrue(photo.waitForExistence(timeout: 4))
        try voiceOver.enable()
        var spoken = try voiceOver.currentSpeech().utterance
        for _ in 0..<8 where !spoken.contains("1.00") {
            spoken = try voiceOver.moveForward().utterance
        }
        print("VOICEOVER_PHOTO", spoken)
        XCTAssertTrue(spoken.contains("1.00"))
        XCTAssertTrue(spoken.contains("照片"))
        XCTAssertTrue(spoken.localizedCaseInsensitiveContains("adjustable") || spoken.contains("可调整"), spoken)
#else
        throw XCTSkip("VoiceOver service requires the iOS 27 SDK.")
#endif
    }

    func testLongDisplayNamesAtAccessibilitySize() {
        exerciseLongDisplayNames(largeText: true)
    }

    func testLongDisplayNamesAtStandardSize() {
        exerciseLongDisplayNames(largeText: false)
    }

    private func exerciseLongDisplayNames(largeText: Bool) {
        let app = readabilityApp(largeText: largeText)
        app.launchEnvironment["TESSERAE_UI_TEST_LONG_DISPLAY_NAMES"] = "1"
        app.launch()
        let demo = app.buttons["使用演示数据体验"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        for _ in 0..<10 where !demo.isHittable { app.swipeUp() }
        demo.tap()
        XCTAssertTrue(app.buttons["root-settings"].waitForExistence(timeout: 5))
        let desk = app.buttons["display-card-e1004-desk"]
        // A persisted reorder can put the other long card first. LazyVStack
        // creates the second card only after scrolling near it.
        for _ in 0..<12 where !desk.exists { app.swipeUp() }
        XCTAssertTrue(desk.exists)
        XCTAssertTrue(desk.label.contains("第二工作区"))
        let prefix = largeText ? "SE AX5 long names" : "SE standard long names"
        readabilityAttachment(app, "\(prefix) displays")
        if largeText {
            app.swipeUp()
            readabilityAttachment(app, "\(prefix) display name wrapping")
            app.swipeUp()
            readabilityAttachment(app, "\(prefix) display hardware")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let portrait = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.height > app.frame.width }, object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 5), .completed)
        XCTAssertTrue(app.buttons["root-send-action"].firstMatch.isHittable)
        readabilityAttachment(app, "\(prefix) portrait after device turn")
        XCUIDevice.shared.orientation = .portrait

        app.buttons["root-send-action"].tap()
        let deskTarget = app.buttons["send-display-e1004-desk"]
        let kitchenTarget = app.buttons["send-display-picpak-kitchen"]
        XCTAssertTrue(deskTarget.waitForExistence(timeout: 4))
        XCTAssertTrue(deskTarget.label.contains("第二工作区"))
        XCTAssertTrue(deskTarget.isSelected || kitchenTarget.isSelected)
        for _ in 0..<10 where !kitchenTarget.isHittable { app.swipeUp() }
        XCTAssertTrue(kitchenTarget.isHittable)
        XCTAssertTrue(kitchenTarget.label.contains("东侧窗边"))
        let wasSelected = kitchenTarget.isSelected
        kitchenTarget.tap()
        XCTAssertEqual(kitchenTarget.isSelected, !wasSelected)
        if wasSelected {
            kitchenTarget.tap()
            XCTAssertTrue(kitchenTarget.isSelected)
        }
        readabilityAttachment(app, "\(prefix) selected targets")
        app.buttons["root-send-close"].tap()

        let manage = app.buttons["manage-lineups"]
        for _ in 0..<12 where !manage.isHittable { app.swipeDown() }
        manage.tap()
        let lineup = app.buttons["lineup-card-kitchen-deck"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 4))
        for _ in 0..<8 where !lineup.isHittable { app.swipeUp() }
        lineup.tap()
        app.buttons["lineup-edit"].tap()
        let name = app.textFields["lineup-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        name.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(name.isHittable)
        readabilityAttachment(app, "\(prefix) editor keyboard")
        XCTAssertTrue(app.buttons["lineup-editor-exit"].isHittable)
    }

    func testChineseScreensInLightMode() {
        exerciseReadabilityScreens(app: readabilityApp(largeText: false, scheme: "light"), largeText: false, prefix: "Chinese standard light")
    }

    private func exerciseReadabilityScreens(app: XCUIApplication, largeText: Bool, prefix: String) {
        app.launch()
        let demo = app.buttons["使用演示数据体验"]
        XCTAssertTrue(demo.waitForExistence(timeout: 5))
        for _ in 0..<10 where !demo.isHittable { app.swipeUp() }
        readabilityAttachment(app, "\(prefix) onboarding actions")
        XCTAssertTrue(demo.isHittable)
        demo.tap()
        let settings = app.buttons["root-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        readabilityAttachment(app, "\(prefix) displays")
        if largeText {
            app.swipeUp()
            readabilityAttachment(app, "\(prefix) display metrics")
        }
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["触感反馈"].exists)
        readabilityAttachment(app, "\(prefix) settings")
        app.swipeUp()
        readabilityAttachment(app, "\(prefix) settings privacy")
        app.buttons["完成"].tap()

        app.tabBars.firstMatch.buttons["图库"].tap()
        let family = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(family.waitForExistence(timeout: 4))
        if largeText { XCTAssertGreaterThan(family.frame.width, app.frame.width * 0.8) }
        readabilityAttachment(app, "\(prefix) gallery folders")
        family.tap()
        XCTAssertTrue(app.buttons["gallery-add-photos"].waitForExistence(timeout: 4))
        readabilityAttachment(app, "\(prefix) gallery photos")

        app.tabBars.firstMatch.buttons["显示屏"].tap()
        app.buttons["manage-lineups"].tap()
        let lineup = app.buttons["lineup-card-kitchen-deck"]
        XCTAssertTrue(lineup.waitForExistence(timeout: 4))
        for _ in 0..<6 where !lineup.isHittable { app.swipeUp() }
        if largeText { XCTAssertGreaterThan(lineup.frame.height, 100) }
        readabilityAttachment(app, "\(prefix) Lineups")
        lineup.tap()
        let enabled = app.switches["lineup-enabled-on"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 4))
        enabled.tap()
        XCTAssertTrue(app.switches["lineup-enabled-off"].waitForExistence(timeout: 3))
        readabilityAttachment(app, "\(prefix) Lineup detail")
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.textFields["lineup-editor-name"].waitForExistence(timeout: 4))
        readabilityAttachment(app, "\(prefix) Lineup editor")
        app.buttons["lineup-editor-exit"].tap()
    }

    func testChineseAccessibilityBluetoothMaintenanceInDarkMode() {
        let app = readabilityApp()
        app.launchEnvironment["TESSERAE_UI_TEST_PICPAK_BLE"] = "1"
        app.launch()
        let nearby = app.buttons["onboarding-nearby-devices"]
        XCTAssertTrue(nearby.waitForExistence(timeout: 4))
        for _ in 0..<10 where !nearby.isHittable { app.swipeUp() }
        nearby.tap()
        XCTAssertTrue(app.navigationBars["附近的显示屏"].waitForExistence(timeout: 4))
        readabilityAttachment(app, "Chinese AX5 dark nearby displays")
        app.buttons.containing(.staticText, identifier: "Tesserae-A1B2C3").firstMatch.tap()
        let proceed = app.buttons["继续"]
        XCTAssertTrue(proceed.waitForExistence(timeout: 4))
        for _ in 0..<4 where !proceed.isHittable { app.swipeUp() }
        XCTAssertTrue(proceed.isHittable)
        readabilityAttachment(app, "Chinese AX5 dark Bluetooth introduction")
        proceed.tap()
        let code = app.buttons["输入 6 位验证码"]
        XCTAssertTrue(code.waitForExistence(timeout: 3))
        for _ in 0..<4 where !code.isHittable { app.swipeUp() }
        readabilityAttachment(app, "Chinese AX5 dark Bluetooth verification")
        code.tap()
        XCTAssertTrue(app.navigationBars["维护"].waitForExistence(timeout: 4))
        let speed = app.buttons["nearby-refresh-speed"]
        for _ in 0..<6 where !speed.isHittable { app.swipeUp() }
        XCTAssertTrue(speed.isHittable)
        readabilityAttachment(app, "Chinese AX5 dark Bluetooth maintenance")
        speed.tap()
        XCTAssertTrue(app.buttons["10 秒"].waitForExistence(timeout: 3))
        app.buttons["10 秒"].tap()
        XCTAssertTrue(app.navigationBars["维护"].exists)
    }

    private func readabilityApp(largeText: Bool = true, scheme: String = "dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = scheme
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
        ]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        return app
    }

    private func readabilityAttachment(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
        XCTAssertTrue(app.buttons["输入服务器地址"].exists)
        XCTAssertFalse(app.buttons["扫描配对二维码"].exists)

        app.buttons["使用演示数据体验"].tap()
        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["显示屏"].waitForExistence(timeout: 3))
        XCTAssertTrue(tabBar.buttons["仪表盘"].exists)
        XCTAssertTrue(tabBar.buttons["图库"].exists)
        XCTAssertTrue(tabBar.buttons["活动"].exists)
        XCTAssertTrue(app.buttons["root-send-action"].exists)
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
        XCTAssertTrue(
            app.buttons["root-send-action"].waitForExistence(timeout: 3)
        )
        app.buttons["root-send-action"].tap()

        let deskTarget = app.buttons["send-display-e1004-desk"]
        let kitchenTarget = app.buttons["send-display-picpak-kitchen"]
        XCTAssertTrue(deskTarget.waitForExistence(timeout: 2))
        XCTAssertTrue(kitchenTarget.exists)
        XCTAssertTrue(app.buttons["Stretch"].exists)
        XCTAssertTrue(app.buttons["Center"].exists)
        XCTAssertFalse(app.buttons["More"].exists)
        let previewPicker = app.descendants(matching: .any)[
            "send-preview-display-picker"
        ]
        let previewPickerButton = app.buttons["send-preview-display-picker"]
        XCTAssertTrue(previewPicker.waitForExistence(timeout: 2))
        XCTAssertFalse(previewPickerButton.exists)
        for _ in 0..<4 where !deskTarget.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(deskTarget.isHittable)
        let targetList = app.staticTexts["Displays"].firstMatch
        XCTAssertTrue(targetList.waitForExistence(timeout: 2))
        let initialTargetListY = targetList.frame.minY
        let initiallySelectedTarget = previewPicker.label.contains("Kitchen")
            ? kitchenTarget
            : deskTarget
        let secondTarget = previewPicker.label.contains("Kitchen")
            ? deskTarget
            : kitchenTarget
        XCTAssertTrue(initiallySelectedTarget.isHittable)
        initiallySelectedTarget.tap()
        XCTAssertTrue(previewPicker.label.contains("None selected"))
        XCTAssertFalse(previewPickerButton.exists)
        XCTAssertEqual(
            targetList.frame.minY,
            initialTargetListY,
            accuracy: 1
        )
        initiallySelectedTarget.tap()
        XCTAssertFalse(previewPicker.label.contains("None selected"))
        secondTarget.tap()
        XCTAssertEqual(
            targetList.frame.minY,
            initialTargetListY,
            accuracy: 1
        )
        XCTAssertTrue(previewPickerButton.waitForExistence(timeout: 2))
        let previewPickerFrame = previewPicker.frame
        let previewWasKitchen = previewPicker.label.contains("Kitchen")
        previewPickerButton.tap()
        let otherPreviewOption = app.buttons[
            previewWasKitchen
                ? "send-preview-display-e1004-desk"
                : "send-preview-display-picpak-kitchen"
        ]
        XCTAssertTrue(otherPreviewOption.waitForExistence(timeout: 2))
        otherPreviewOption.tap()
        XCTAssertEqual(
            previewPicker.frame.midX,
            previewPickerFrame.midX,
            accuracy: 1
        )
        XCTAssertTrue(
            previewPicker.label.contains(
                previewWasKitchen ? "Desk" : "Kitchen"
            )
        )
        XCTAssertTrue(previewPicker.label.contains("·"))
        XCTAssertTrue(previewPicker.label.contains("×"))
        for _ in 0..<4 where kitchenTarget.frame.minY < 110 {
            app.swipeDown()
        }
        XCTAssertGreaterThanOrEqual(kitchenTarget.frame.minY, 110)
        let targetListYBeforeKitchenToggle = targetList.frame.minY
        kitchenTarget.tap()
        XCTAssertEqual(
            targetList.frame.minY,
            targetListYBeforeKitchenToggle,
            accuracy: 1
        )
        XCTAssertTrue(previewPickerButton.waitForNonExistence(timeout: 2))
        kitchenTarget.tap()
        XCTAssertTrue(previewPickerButton.waitForExistence(timeout: 2))
        previewPickerButton.tap()
        let deskPreviewOption = app.buttons[
            "send-preview-display-e1004-desk"
        ]
        XCTAssertTrue(deskPreviewOption.waitForExistence(timeout: 2))
        deskPreviewOption.tap()

        app.buttons["Use Sample"].tap()
        let changePhoto = app.buttons["send-change-photo"]
        XCTAssertTrue(changePhoto.waitForExistence(timeout: 2))
        XCTAssertFalse(
            app.descendants(matching: .any)["send-preview-metadata"].exists
        )
        XCTAssertTrue(previewPicker.label.contains("Desk"))
        XCTAssertTrue(previewPicker.label.contains("·"))
        XCTAssertTrue(previewPicker.label.contains("×"))
        XCTAssertFalse(app.staticTexts["Previewing on"].exists)
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
        let portraitZoom = framingZoom.label
        XCTAssertTrue(resetFraming.isEnabled)
        XCTAssertGreaterThanOrEqual(
            imagePreview.frame.minX,
            panelPreview.frame.minX - 1
        )
        XCTAssertLessThanOrEqual(
            imagePreview.frame.maxX,
            panelPreview.frame.maxX + 1
        )
        previewPickerButton.tap()
        let kitchenFramingOption = app.buttons[
            "send-preview-display-picpak-kitchen"
        ]
        XCTAssertTrue(kitchenFramingOption.waitForExistence(timeout: 2))
        kitchenFramingOption.tap()
        XCTAssertTrue(previewPicker.label.contains("Kitchen"))
        XCTAssertEqual(framingZoom.label, initialZoom)
        XCTAssertFalse(resetFraming.isEnabled)

        previewPickerButton.tap()
        let deskFramingOption = app.buttons[
            "send-preview-display-e1004-desk"
        ]
        XCTAssertTrue(deskFramingOption.waitForExistence(timeout: 2))
        deskFramingOption.tap()
        XCTAssertTrue(previewPicker.label.contains("Desk"))
        XCTAssertEqual(framingZoom.label, portraitZoom)
        XCTAssertTrue(resetFraming.isEnabled)
        let previewScreenshot = XCTAttachment(screenshot: app.screenshot())
        previewScreenshot.name = "Send Fill Preview"
        previewScreenshot.lifetime = .keepAlways
        add(previewScreenshot)
        let previewSendButton = app.buttons["Send to Displays"]
        XCTAssertFalse(app.switches["send-override-quiet-hours"].exists)
        XCTAssertTrue(previewSendButton.isEnabled)
        previewSendButton.tap()

        let sentBanner = app.descendants(matching: .any)[
            "send-success-banner"
        ]
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
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

    func testAutoFramingAppliesResetsAndSends() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_AUTO_FRAMING"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 5))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 5))
        app.buttons["root-send-action"].tap()
        let picker = app.descendants(matching: .any)["send-preview-display-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        if !picker.label.contains("Desk") { app.buttons["send-display-e1004-desk"].tap() }
        let sample = app.buttons["Use Sample"]
        for _ in 0..<3 where !sample.isHittable { app.swipeUp() }
        sample.tap()
        let auto = app.buttons["send-auto-framing"]
        XCTAssertTrue(auto.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(auto.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(auto.frame.height, 44 - 0.001)
        let reset = app.buttons["send-framing-reset"]
        XCTAssertGreaterThanOrEqual(reset.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(reset.frame.height, 44 - 0.001)
        XCTAssertEqual(auto.value as? String, "Adjusted")
        let hint = app.descendants(matching: .any)["send-framing-hint"]
        XCTAssertTrue(hint.exists)
        let zoom = app.staticTexts["send-framing-zoom"]
        XCTAssertEqual(zoom.label, "2.0×")
        XCTAssertTrue(reset.isEnabled)
        let controls = app.descendants(matching: .any)["send-framing-controls"]
        let controlsHeight = controls.frame.height
        XCTAssertLessThanOrEqual(hint.frame.maxX, auto.frame.minX + 1)
        XCTAssertLessThanOrEqual(auto.frame.maxX, zoom.frame.minX)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Auto Frame applied"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.staticTexts["send-auto-framing-feedback"].exists)
        XCTAssertFalse(app.buttons["send-framing-hint"].exists)
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        XCTAssertEqual(auto.value as? String, "Manual")
        XCTAssertEqual(controls.frame.height, controlsHeight, accuracy: 0.5)
        auto.tap()
        XCTAssertTrue(reset.isEnabled)
        auto.tap()
        XCTAssertEqual(auto.value as? String, "Unchanged")
        XCTAssertEqual(controls.frame.height, controlsHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(hint.frame.maxX, auto.frame.minX + 1)
        XCTAssertLessThanOrEqual(auto.frame.maxX, zoom.frame.minX)
        let send = app.buttons["Send to Displays"]
        for _ in 0..<3 where !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["send-success-banner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
    }

    func testLibraryPhotoSendClosesBackToPhotoDetail() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 5))
        app.buttons["Explore with Demo Data"].tap()
        let library = app.buttons["Library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        library.tap()
        let folder = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(folder.waitForExistence(timeout: 3))
        folder.tap()
        let photo = app.buttons["gallery-image-image_family_01"]
        XCTAssertTrue(photo.waitForExistence(timeout: 3))
        photo.tap()
        let sendPhoto = app.buttons["gallery-send-image"]
        XCTAssertTrue(sendPhoto.waitForExistence(timeout: 3))
        sendPhoto.tap()
        let send = app.buttons["send-submit"]
        XCTAssertTrue(send.waitForExistence(timeout: 3))
        scrollToButton(send, app: app)
        XCTAssertTrue(send.isEnabled)
        send.tap()
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(sendPhoto.isHittable)
    }

    func testFailedPhotoSendPreservesDraftAndClosesAfterRetry() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_IMAGE_SEND_FAILURE_ONCE"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 5))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 5))
        app.buttons["root-send-action"].tap()

        let desk = app.buttons["send-display-e1004-desk"]
        let kitchen = app.buttons["send-display-picpak-kitchen"]
        XCTAssertTrue(desk.waitForExistence(timeout: 3))
        scrollToButton(desk, app: app)
        if !desk.isSelected { desk.tap() }
        if kitchen.isSelected { kitchen.tap() }
        XCTAssertTrue(desk.isSelected)
        XCTAssertFalse(kitchen.isSelected)

        let sample = app.buttons["Use Sample"]
        scrollToButton(sample, app: app)
        sample.tap()
        let image = app.descendants(matching: .any)["selected-image-preview"]
        XCTAssertTrue(image.waitForExistence(timeout: 3))
        image.pinch(withScale: 1.6, velocity: 1)
        let reset = app.buttons["send-framing-reset"]
        XCTAssertTrue(reset.waitForExistence(timeout: 3))
        XCTAssertTrue(reset.isEnabled)
        let preview = app.descendants(matching: .any)["send-panel-preview"]
        let framing = preview.value as? String
        let zoom = app.staticTexts["send-framing-zoom"].label

        let send = app.buttons["send-submit"]
        scrollToButton(send, app: app)
        send.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.alerts.staticTexts["Test send failed. Try again."].exists)
        app.alerts.buttons["OK"].tap()
        XCTAssertTrue(app.buttons["root-send-close"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["send-success-banner"].exists)
        XCTAssertTrue(app.buttons["send-change-photo"].exists)
        XCTAssertEqual(preview.value as? String, framing)
        XCTAssertEqual(app.staticTexts["send-framing-zoom"].label, zoom)
        XCTAssertTrue(desk.isSelected)
        XCTAssertFalse(kitchen.isSelected)
        XCTAssertTrue(send.isEnabled)

        send.tap()
        XCTAssertTrue(app.descendants(matching: .any)["send-success-banner"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["root-send-close"].waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["root-send-action"].isHittable)
        app.buttons["root-send-action"].tap()
        XCTAssertTrue(app.buttons["Use Sample"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["send-change-photo"].exists,
            "A completed draft must not reappear when opening Send again.")
        XCTAssertFalse(app.buttons["send-submit"].isEnabled)
    }

    func testAutoFramingChineseAccessibilityLayout() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_AUTO_FRAMING"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["使用演示数据体验"].waitForExistence(timeout: 5))
        app.buttons["使用演示数据体验"].tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 5))
        app.buttons["root-send-action"].tap()
        let sample = app.buttons["使用示例"]
        for _ in 0..<6 where !sample.isHittable { app.swipeUp() }
        XCTAssertTrue(sample.isHittable)
        sample.tap()
        let auto = app.buttons["send-auto-framing"]
        XCTAssertTrue(auto.waitForExistence(timeout: 3))
        for _ in 0..<6 where !auto.isHittable { app.swipeDown() }
        XCTAssertTrue(auto.isHittable)
        XCTAssertEqual(auto.value as? String, "已调整")
        XCTAssertFalse(app.staticTexts["send-auto-framing-feedback"].exists)
        let panel = app.descendants(matching: .any)["send-panel-preview"]
        let image = app.descendants(matching: .any)["selected-image-preview"]
        let reset = app.buttons["send-framing-reset"]
        let controls = app.descendants(matching: .any)["send-framing-controls"]
        let hint = app.descendants(matching: .any)["send-framing-hint"]
        let zoom = app.staticTexts["send-framing-zoom"]
        XCTAssertGreaterThanOrEqual(auto.frame.minX, panel.frame.minX)
        XCTAssertGreaterThan(auto.frame.minY, image.frame.maxY)
        XCTAssertLessThanOrEqual(auto.frame.maxX, panel.frame.maxX)
        XCTAssertLessThanOrEqual(reset.frame.maxX, panel.frame.maxX)
        XCTAssertLessThanOrEqual(hint.frame.maxX, auto.frame.minX + 1)
        XCTAssertLessThanOrEqual(auto.frame.maxX, zoom.frame.minX)
        XCTAssertLessThanOrEqual(zoom.frame.maxX, reset.frame.minX)
        // Accessibility can round the shared bottom edge to slightly different values.
        XCTAssertLessThanOrEqual(controls.frame.maxY, panel.frame.maxY + 0.5)
        let target = app.descendants(matching: .any)["send-preview-display-picker"]
        XCTAssertGreaterThan(target.frame.minY, controls.frame.maxY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Auto Frame Chinese accessibility"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertFalse(app.buttons["send-framing-hint"].exists)
        XCTAssertTrue(auto.isHittable)
        let fit = app.buttons["send-image-fit-picker"]
        for _ in 0..<8 where !fit.isHittable {
            // Scroll outside the photo, where a drag intentionally edits its crop.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.96, dy: 0.25)
                ))
        }
        XCTAssertTrue(fit.isHittable)
        readabilityAttachment(app, "Chinese AX5 preview target full text")
        fit.tap()
        XCTAssertTrue(app.buttons["适应"].waitForExistence(timeout: 3))
        readabilityAttachment(app, "Chinese AX5 dark image fit menu")
        app.buttons["适应"].tap()
        XCTAssertFalse(app.buttons["send-auto-framing"].exists)
    }

    func testManualConnectionAgainstFixtureServer() throws {
        let app = try launchFixtureConnectedApp()
        XCTAssertFalse(app.staticTexts["Connected through Companion API"].exists)
    }

    func testRepairingSameFixtureServerResetsLibraryNavigation() throws {
        let app = try launchFixtureConnectedApp()
        let tabBar = app.tabBars.firstMatch
        let libraryTab = tabBar.buttons["Library"]
        XCTAssertTrue(libraryTab.waitForExistence(timeout: 5))
        libraryTab.tap()

        let family = app.buttons["gallery-folder-folder_family"]
        XCTAssertTrue(family.waitForExistence(timeout: 5))
        family.tap()
        let photo = app.buttons["gallery-image-image_family_01"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        photo.tap()
        let photoPager = app.descendants(matching: .any)["gallery-photo-pager"]
        XCTAssertTrue(photoPager.waitForExistence(timeout: 5))

        let displaysTab = tabBar.buttons["Displays"]
        displaysTab.tap()
        let settings = app.buttons["root-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let otherServers = app.buttons["Other Servers"]
        XCTAssertTrue(otherServers.waitForExistence(timeout: 3))
        otherServers.tap()
        XCTAssertTrue(app.navigationBars["Tesserae Servers"].waitForExistence(timeout: 3))

        // The same fixture returns the same instance ID. Only a fresh session
        // identity can reset the old Library path and the Settings presentation.
        connectUsingPrefilledFixtureAddress(in: app)
        let navigationReset = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                displaysTab.isSelected && displaysTab.isHittable
                    && !app.navigationBars["Settings"].exists
                    && !app.navigationBars["Connect Manually"].exists
            },
            object: nil
        )
        XCTAssertEqual(XCTWaiter.wait(for: [navigationReset], timeout: 8), .completed)

        libraryTab.tap()
        XCTAssertTrue(family.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["gallery-create-folder"].exists)
        XCTAssertFalse(photoPager.exists)
        XCTAssertFalse(app.buttons["gallery-add-photos"].exists)
    }

    private func launchFixtureConnectedApp() throws -> XCUIApplication {
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

        connectUsingPrefilledFixtureAddress(in: app)

        let kitchen = app.buttons["display-card-picpak-kitchen"]
        if !kitchen.waitForExistence(timeout: 5) {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Fixture connection hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
            let alert = app.alerts["Something Went Wrong"]
            let details = alert.staticTexts.allElementsBoundByIndex
                .map { element in element.label }
                .joined(separator: " ")
            XCTFail(details.isEmpty ? "Live connection did not complete." : details)
        }
        return app
    }

    private func connectUsingPrefilledFixtureAddress(in app: XCUIApplication) {
        let enterAddress = app.buttons["Enter Server Address"]
        XCTAssertTrue(enterAddress.waitForExistence(timeout: 3))
        enterAddress.tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 3))
        app.buttons["Connect"].tap()
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
