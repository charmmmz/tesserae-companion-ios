import XCTest

@MainActor
final class TesseraeCompanionUITests: XCTestCase {
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
        let dashboardsTab = app.tabBars.firstMatch.buttons["rectangle.grid.2x2"]
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
                "The official Tesserae app for quick, everyday display tasks on iPhone."
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
        XCTAssertFalse(app.buttons["Allow This iPhone"].exists)
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
        XCTAssertGreaterThan(sendAction.frame.minY, app.frame.height * 0.7)
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

    func testRootToolbarsKeepSettingsAndContextActionsConsistent() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        let tabBar = app.tabBars.firstMatch
        let settings = app.buttons["root-settings"]

        XCTAssertTrue(settings.waitForExistence(timeout: 2))
        XCTAssertTrue(settings.isHittable)
        XCTAssertLessThanOrEqual(settings.frame.maxX, app.frame.maxX)
        XCTAssertFalse(app.buttons["dashboard-layout-toggle"].exists)
        XCTAssertFalse(app.buttons["clear-local-activity"].exists)

        tabBar.buttons["Dashboards"].tap()
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

        XCTAssertFalse(tabBar.buttons["Send"].exists)
        app.buttons["root-send-action"].tap()
        let sendSettingsQuery = app.buttons.matching(
            identifier: "root-settings"
        )
        XCTAssertTrue(sendSettingsQuery.firstMatch.waitForExistence(timeout: 2))
        let sendSettings = sendSettingsQuery.allElementsBoundByIndex.first {
            $0.isHittable
        }
        XCTAssertNotNil(sendSettings)
        if let sendSettings {
            XCTAssertLessThanOrEqual(sendSettings.frame.maxX, app.frame.maxX)
        }
        XCTAssertFalse(app.buttons["dashboard-layout-toggle"].isHittable)
        XCTAssertFalse(app.buttons["clear-local-activity"].isHittable)

        app.buttons["root-send-close"].tap()
        tabBar.buttons["Activity"].tap()
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
        app.tabBars.firstMatch.buttons["Dashboards"].tap()

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
        let dashboardLayoutToggle = app.buttons["dashboard-layout-toggle"]
        XCTAssertTrue(dashboardLayoutToggle.waitForExistence(timeout: 2))
        if dashboardLayoutToggle.label == "Use Card View" {
            dashboardLayoutToggle.tap()
        }
        let kitchenDashboardGroup = app.buttons[
            "dashboard-section-toggle-display-picpak-kitchen"
        ]
        XCTAssertTrue(kitchenDashboardGroup.waitForExistence(timeout: 2))
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
            "The fitted sheet must keep its primary action fully visible."
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
        app.buttons["Use Sample"].tap()
        let sendButton = app.buttons["Send to Displays"]
        XCTAssertTrue(sendButton.isEnabled)
        let sendButtonHeight = sendButton.frame.height
        sendButton.tap()

        let sentBanner = app.descendants(matching: .any)[
            "send-success-banner"
        ]
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 3))
        XCTAssertEqual(
            sendButton.frame.height,
            sendButtonHeight,
            accuracy: 1
        )

        app.buttons["root-send-close"].tap()
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

    func testDisplayDetailsOpenAsSheet() {
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
        XCTAssertTrue(detailNavigation.buttons["Close"].exists)
        XCTAssertFalse(detailNavigation.buttons["Displays"].exists)
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

        detailNavigation.buttons["Close"].tap()
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
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "500"
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
        linkField.typeText("https://example.com/news")

        let sendButton = app.buttons["Send to Displays"]
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
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 3))
        XCTAssertTrue(
            sentBanner.label.contains("Sent to Displays")
        )

        app.buttons["root-send-close"].tap()
        let transientMessageDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: sentBanner
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [transientMessageDismissed], timeout: 2),
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
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        app.tabBars.firstMatch.buttons["Dashboards"].tap()

        let photoFrame = app.staticTexts[
            "dashboard-title-photo-frame-display-picpak-kitchen"
        ]
        let pantry = app.staticTexts[
            "dashboard-title-pantry-display-picpak-kitchen"
        ]
        XCTAssertTrue(photoFrame.waitForExistence(timeout: 2))
        XCTAssertTrue(pantry.waitForExistence(timeout: 2))
        for _ in 0..<5 where !photoFrame.isHittable || !pantry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(photoFrame.isHittable)
        XCTAssertTrue(pantry.isHittable)
        let upper = photoFrame.frame.minY < pantry.frame.minY
            ? photoFrame
            : pantry
        let lower = photoFrame.frame.minY < pantry.frame.minY
            ? pantry
            : photoFrame

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
        let previewSendButtonHeight = previewSendButton.frame.height
        previewSendButton.tap()

        let sentBanner = app.descendants(matching: .any)[
            "send-success-banner"
        ]
        XCTAssertTrue(sentBanner.waitForExistence(timeout: 3))
        XCTAssertEqual(
            previewSendButton.frame.height,
            previewSendButtonHeight,
            accuracy: 1
        )

        app.buttons["root-send-close"].tap()
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
        let reset = app.buttons["send-framing-reset"]
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
    }

    func testAutoFramingChineseAccessibilityLayout() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_AUTO_FRAMING"] = "1"
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
