import XCTest

@MainActor
final class LineupsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoLineupReadAndControlFlow() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()

        XCTAssertFalse(app.tabBars.firstMatch.buttons["Lineups"].exists)

        let manageLineups = app.buttons["manage-lineups"]
        XCTAssertTrue(manageLineups.waitForExistence(timeout: 3))
        manageLineups.tap()

        let lineupCard = app.buttons["lineup-card-kitchen-deck"]
        XCTAssertTrue(lineupCard.waitForExistence(timeout: 3))
        XCTAssertTrue(lineupCard.label.contains("Kitchen deck"))
        XCTAssertTrue(lineupCard.label.contains("enabled"))
        XCTAssertTrue(lineupCard.label.contains("Showing Pantry"))
        XCTAssertFalse(app.staticTexts["Enabled"].exists)
        XCTAssertFalse(
            app.staticTexts["Schedules, decks, and rotations"].exists
        )

        let listScreenshot = XCTAttachment(screenshot: app.screenshot())
        listScreenshot.name = "Lineups List"
        listScreenshot.lifetime = .keepAlways
        add(listScreenshot)

        lineupCard.tap()

        let enabledControl = app.buttons["lineup-enabled-on"]
        XCTAssertTrue(enabledControl.waitForExistence(timeout: 3))
        XCTAssertTrue(enabledControl.isEnabled)
        XCTAssertTrue(enabledControl.isHittable)
        enabledControl.tap()
        let disabledControl = app.buttons["lineup-enabled-off"]
        XCTAssertTrue(disabledControl.waitForExistence(timeout: 3))
        XCTAssertTrue(disabledControl.isEnabled)

        disabledControl.tap()
        XCTAssertTrue(enabledControl.waitForExistence(timeout: 3))

        XCTAssertFalse(app.staticTexts["Select a target"].exists)
        XCTAssertTrue(app.staticTexts["Kitchen"].exists)
        XCTAssertFalse(app.staticTexts["Now Showing"].exists)
        XCTAssertFalse(
            app.descendants(matching: .any)["lineup-current-preview"].exists
        )
        XCTAssertFalse(app.buttons["lineup-previous"].exists)
        XCTAssertFalse(app.buttons["lineup-next"].exists)
        XCTAssertFalse(app.staticTexts["1 of 2"].exists)
        XCTAssertFalse(app.staticTexts["Current"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["lineup-playing-pantry"].exists
        )
        XCTAssertFalse(app.staticTexts["30 min"].exists)

        let currentDashboard = app.buttons["lineup-dashboard-pantry"]
        XCTAssertTrue(currentDashboard.exists)
        currentDashboard.tap()
        XCTAssertTrue(
            app.staticTexts["lineup-dashboard-sheet-title"]
                .waitForExistence(timeout: 2)
        )
        let pantryPreview = app.descendants(matching: .any)[
            "lineup-dashboard-preview-pantry"
        ]
        XCTAssertTrue(pantryPreview.waitForExistence(timeout: 2))
        let pantryCaption = app.staticTexts[
            "lineup-dashboard-preview-caption-pantry"
        ]
        XCTAssertTrue(pantryCaption.waitForExistence(timeout: 2))
        XCTAssertEqual(pantryCaption.label, "Pantry · 800 × 480")
        XCTAssertGreaterThan(
            pantryCaption.frame.minY,
            pantryPreview.frame.maxY,
            "Dashboard name and resolution should sit below the preview."
        )
        XCTAssertFalse(app.buttons["Now Playing"].isEnabled)
        app.buttons["Cancel"].tap()

        app.swipeUp()
        let details = app.buttons["lineup-details-disclosure"]
        XCTAssertTrue(details.exists)
        XCTAssertTrue(details.isHittable)
        details.tap()

        let backgroundRefresh = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] %@", "Background refresh")
        ).firstMatch
        XCTAssertTrue(
            backgroundRefresh.waitForExistence(timeout: 3)
        )
        for hiddenLabel in ["Smart sync", "Mode", "Priority", "Minimum hold"] {
            let hiddenField = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", hiddenLabel)
            ).firstMatch
            XCTAssertFalse(hiddenField.exists)
        }

        app.swipeDown()
        app.swipeDown()
        XCTAssertTrue(app.buttons["lineup-play-morning"].exists)
        app.buttons["lineup-dashboard-morning"].tap()
        XCTAssertTrue(
            app.staticTexts["lineup-dashboard-sheet-title"]
                .waitForExistence(timeout: 2)
        )
        let morningPreview = app.descendants(matching: .any)[
            "lineup-dashboard-preview-morning"
        ]
        XCTAssertTrue(morningPreview.waitForExistence(timeout: 2))
        let morningCaption = app.staticTexts[
            "lineup-dashboard-preview-caption-morning"
        ]
        XCTAssertTrue(morningCaption.waitForExistence(timeout: 2))
        XCTAssertEqual(morningCaption.label, "Morning · 800 × 480")
        XCTAssertGreaterThan(
            morningCaption.frame.minY,
            morningPreview.frame.maxY,
            "Lineup Dashboard name and resolution should sit below the preview."
        )
        let playOnKitchen = app.buttons["Play on Kitchen"]
        XCTAssertTrue(playOnKitchen.isEnabled)
        let previewSheetScreenshot = XCTAttachment(screenshot: app.screenshot())
        previewSheetScreenshot.name = "Lineup Dashboard Preview Sheet"
        previewSheetScreenshot.lifetime = .keepAlways
        add(previewSheetScreenshot)
        playOnKitchen.tap()
        let morningIsShowing = NSPredicate(format: "exists == true")
        expectation(
            for: morningIsShowing,
            evaluatedWith: app.descendants(matching: .any)["lineup-playing-morning"]
        )
        waitForExpectations(timeout: 5)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Lineup Detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testCreateManualLineupFlow() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()

        let createButton = app.buttons["lineup-create"]
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        app.buttons["lineup-intent-manual"].tap()
        assertCleanEditor(app, name: "Manual", requiresDisplay: true)

        let nameField = app.textFields["lineup-editor-name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.tap()
        nameField.typeText("Weekend Rotation")

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 2))
        app.swipeUp()
        expectation(
            for: NSPredicate(format: "exists == false"),
            evaluatedWith: keyboard
        )
        waitForExpectations(timeout: 2)

        app.buttons["lineup-editor-displays"].tap()
        app.buttons["lineup-editor-display-picpak-kitchen"].tap()

        app.buttons["lineup-editor-dashboards"].tap()
        XCTAssertTrue(app.searchFields["Search Dashboards"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Kitchen"].exists)
        app.buttons["lineup-editor-dashboard-pantry"].tap()
        app.buttons["lineup-editor-dashboard-photo-frame"].tap()
        XCTAssertFalse(app.buttons["Edit"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)[
                "lineup-editor-selected-dashboard-pantry"
            ].exists
        )
        app.navigationBars["Dashboards"].buttons.firstMatch.tap()

        let saveButton = app.buttons["lineup-editor-save"]
        XCTAssertTrue(saveButton.isEnabled)
        let editorScreenshot = XCTAttachment(screenshot: app.screenshot())
        editorScreenshot.name = "Manual Lineup Editor"
        editorScreenshot.lifetime = .keepAlways
        add(editorScreenshot)
        saveButton.tap()

        let created = app.buttons["lineup-card-weekend_rotation"]
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        XCTAssertTrue(created.label.contains("Weekend Rotation"))
    }

    func testCreateIntervalUsesDashboardBindingAndDurationWheels() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3)
        )
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()
        XCTAssertTrue(app.buttons["lineup-create"].waitForExistence(timeout: 3))
        app.buttons["lineup-create"].tap()
        app.buttons["lineup-intent-interval"].tap()
        assertCleanEditor(app, name: "Keep Fresh", requiresDisplay: false)

        XCTAssertTrue(app.buttons["lineup-editor-displays"].exists)
        XCTAssertTrue(app.buttons["lineup-editor-displays"].label.contains("Follow Dashboard"))
        app.buttons["lineup-editor-dashboards"].tap()
        let search = app.searchFields["Search Dashboards"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.tap()
        search.typeText("Pantry")
        XCTAssertTrue(
            app.buttons["lineup-editor-dashboard-pantry"]
                .waitForExistence(timeout: 2)
        )
        app.buttons["lineup-editor-dashboard-pantry"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["lineup-editor-interval"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertGreaterThanOrEqual(app.pickers.count, 2)
    }

    func testDailyTargetsCanOverrideAndReturnToDashboardBindings() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()
        app.buttons["lineup-create"].tap()
        app.buttons["lineup-intent-daily"].tap()
        assertCleanEditor(app, name: "Daily", requiresDisplay: false)
        let name = app.textFields["lineup-editor-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("Daily Override")
        app.swipeUp()

        app.buttons["lineup-editor-displays"].tap()
        app.buttons["lineup-editor-display-picpak-kitchen"].tap()
        app.buttons["lineup-editor-display-e1004-desk"].tap()
        let targets = XCTAttachment(screenshot: app.screenshot())
        targets.name = "Daily target overrides"
        targets.lifetime = .keepAlways
        add(targets)
        app.buttons["lineup-editor-displays-done"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-displays"].label.contains("2 displays"))
        app.buttons["lineup-editor-dashboards"].tap()
        app.buttons["lineup-editor-dashboard-morning"].tap()
        let save = app.buttons["lineup-editor-save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()

        let created = app.buttons["lineup-card-daily_override"]
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        created.tap()
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-displays"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["lineup-editor-displays"].label.contains("2 displays"))
        app.buttons["lineup-editor-displays"].tap()
        app.buttons["lineup-editor-inherit-displays"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-displays"].label.contains("Follow Dashboard"))
        XCTAssertTrue(app.buttons["lineup-editor-dashboards"].label.contains("Morning"))
        save.tap()
        XCTAssertTrue(app.buttons["lineup-edit"].waitForExistence(timeout: 3))
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-displays"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["lineup-editor-displays"].label.contains("Follow Dashboard"))
    }

    func testCycleSetupRevealsDashboardsAndPreservesTimingWhenChangingDisplay() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "dark"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()
        app.buttons["lineup-create"].tap()
        app.buttons["lineup-intent-cycle"].tap()
        assertCleanEditor(app, name: "Cycle", requiresDisplay: true)

        let name = app.textFields["lineup-editor-name"]
        name.tap()
        name.typeText("Evening Cycle")
        app.swipeUp()
        app.buttons["lineup-editor-displays"].tap()
        app.buttons["lineup-editor-display-picpak-kitchen"].tap()
        let dashboards = app.buttons["lineup-editor-dashboards"]
        XCTAssertTrue(dashboards.waitForExistence(timeout: 2))
        XCTAssertTrue(dashboards.isEnabled)
        dashboards.tap()
        app.buttons["lineup-editor-dashboard-pantry"].tap()
        app.buttons["lineup-editor-dashboard-photo-frame"].tap()
        app.navigationBars["Dashboards"].buttons.firstMatch.tap()

        app.buttons["lineup-editor-duration-photo-frame"].tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 2))
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "10 min")
        attachEditor(app, name: "Duration sheet — compact, dark")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-duration-photo-frame"].label.contains("10 minutes"))

        app.buttons["lineup-editor-displays"].tap()
        app.buttons["lineup-editor-display-e1004-desk"].tap()
        XCTAssertFalse(app.buttons["lineup-editor-duration-pantry"].exists)
        XCTAssertTrue(app.buttons["lineup-editor-duration-photo-frame"].exists)
        XCTAssertFalse(app.buttons["lineup-editor-save"].isEnabled)
        dashboards.tap()
        app.buttons["lineup-editor-dashboard-morning"].tap()
        app.navigationBars["Dashboards"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["lineup-editor-save"].isEnabled)
        attachEditor(app, name: "Cycle — configured, dark")
        app.buttons["lineup-editor-save"].tap()

        let created = app.buttons["lineup-card-evening_cycle"]
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        created.tap()
        app.buttons["lineup-edit"].tap()
        let duration = app.buttons["lineup-editor-duration-photo-frame"]
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        XCTAssertTrue(duration.label.contains("10 minutes"))
        XCTAssertFalse(app.buttons["lineup-editor-duration-pantry"].exists)
    }

    func testCreateDraftProtectsBackAndNestedSheetDismissal() {
        let app = launchLineups()
        app.buttons["lineup-create"].tap()
        app.buttons["lineup-intent-manual"].tap()
        app.buttons["lineup-editor-exit"].tap()
        XCTAssertTrue(app.buttons["lineup-intent-manual"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Discard Changes"].exists)

        app.buttons["lineup-intent-manual"].tap()
        let name = app.textFields["lineup-editor-name"]
        name.tap()
        name.typeText("Draft to keep")
        app.swipeUp()
        app.buttons["lineup-editor-exit"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 2), app.debugDescription)
        app.buttons["Keep Editing"].tap()
        XCTAssertEqual(name.value as? String, "Draft to keep")

        app.buttons["lineup-editor-displays"].tap()
        XCTAssertTrue(app.navigationBars["Displays"].waitForExistence(timeout: 2))
        app.navigationBars["Displays"].buttons.firstMatch.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Discard Changes"].exists)

        app.buttons["lineup-editor-displays"].tap()
        swipeDownSheet(app, title: "Displays")
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 3))
        attachEditor(app, name: "Nested picker — unsaved changes")
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(app.navigationBars["Displays"].exists)
        swipeDownSheet(app, title: "Displays")
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["lineup-create"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.textFields["lineup-editor-name"].exists)
    }

    func testExistingDraftCancelAndDashboardOrdering() {
        let app = launchLineups()
        app.buttons["lineup-card-kitchen-deck"].tap()
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.textFields["lineup-editor-name"].waitForExistence(timeout: 3))
        app.buttons["lineup-editor-exit"].tap()
        XCTAssertTrue(app.buttons["lineup-edit"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["Discard Changes"].exists)

        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-dashboards"].waitForExistence(timeout: 3))
        app.buttons["lineup-editor-dashboards"].tap()
        let pantry = app.descendants(matching: .any)["lineup-editor-selected-dashboard-pantry"].firstMatch
        let morning = app.descendants(matching: .any)["lineup-editor-selected-dashboard-morning"].firstMatch
        XCTAssertLessThan(pantry.frame.minY, morning.frame.minY)
        app.buttons["lineup-editor-selected-dashboard-morning"].tap()
        app.buttons["Move Up"].tap()
        XCTAssertLessThan(morning.frame.minY, pantry.frame.minY)
        attachEditor(app, name: "Dashboard picker — reordered")
        app.buttons["lineup-editor-selected-dashboard-pantry"].tap()
        app.buttons["Remove"].tap()
        XCTAssertFalse(pantry.exists)
        app.buttons["lineup-editor-dashboards-done"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-save"].isEnabled)
        app.buttons["lineup-editor-exit"].tap()
        XCTAssertTrue(app.buttons["Keep Editing"].waitForExistence(timeout: 2))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-dashboards"].label.contains("1 dashboard"))
        app.buttons["lineup-editor-exit"].tap()
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["lineup-edit"].waitForExistence(timeout: 2))
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.buttons["lineup-editor-dashboards"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["lineup-editor-dashboards"].label.contains("2 dashboards"))
    }

    func testCycleTimingAndLongDurationAtAccessibilitySize() {
        let app = launchLineups(intent: "cycle", largeText: true)
        app.buttons["lineup-card-kitchen-deck"].tap()
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(app.textFields["lineup-editor-name"].waitForExistence(timeout: 3))
        let timing = app.buttons["lineup-editor-timing"]
        for _ in 0..<4 where !timing.isHittable { app.swipeUp() }
        timing.tap()
        for _ in 0..<3 where !app.pickerWheels.firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 2))
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "07")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "15")
        attachEditor(app, name: "Cycle timing — accessibility text")
        for _ in 0..<4 where !timing.isHittable { app.swipeDown() }
        timing.tap()
        let duration = app.buttons["lineup-editor-duration-pantry"]
        for _ in 0..<4 where !duration.isHittable { app.swipeDown() }
        duration.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 2))
        app.pickerWheels.element(boundBy: 0).adjust(toPickerWheelValue: "48 hr")
        attachEditor(app, name: "Duration sheet — accessibility text, 48 hours")
        app.buttons["Done"].tap()
        app.buttons["lineup-editor-save"].tap()
        XCTAssertTrue(app.buttons["lineup-edit"].waitForExistence(timeout: 3))
        app.buttons["lineup-edit"].tap()
        XCTAssertTrue(duration.waitForExistence(timeout: 3))
        for _ in 0..<4 where !duration.isHittable { app.swipeUp() }
        duration.tap()
        XCTAssertTrue(app.pickerWheels.firstMatch.waitForExistence(timeout: 2))
        XCTAssertEqual(app.pickerWheels.element(boundBy: 0).value as? String, "48 hr")
        XCTAssertEqual(app.pickerWheels.element(boundBy: 1).value as? String, "20 min")
        app.buttons["Done"].tap()
        for _ in 0..<4 where !timing.isHittable { app.swipeUp() }
        timing.tap()
        for _ in 0..<4 where !app.pickerWheels.firstMatch.isHittable { app.swipeUp() }
        XCTAssertTrue((app.pickerWheels.element(boundBy: 0).value as? String)?.hasPrefix("07") == true)
        XCTAssertTrue((app.pickerWheels.element(boundBy: 1).value as? String)?.hasPrefix("15") == true)
    }

    private func launchLineups(intent: String? = nil, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        if let intent { app.launchEnvironment["TESSERAE_UI_TEST_LINEUP_INTENT"] = intent }
        app.launchArguments += ["-AppleLocale", "en_GB", "-AppleLanguages", "(en)"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityM"]
        }
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()
        XCTAssertTrue(app.buttons["lineup-create"].waitForExistence(timeout: 3))
        return app
    }

    private func swipeDownSheet(_ app: XCUIApplication, title: String) {
        let start = app.navigationBars[title].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.1, thenDragTo: end)
    }

    private func assertCleanEditor(
        _ app: XCUIApplication,
        name: String,
        requiresDisplay: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(app.textFields["lineup-editor-name"].waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(app.buttons["lineup-editor-displays"].exists, file: file, line: line)
        XCTAssertEqual(app.buttons["lineup-editor-dashboards"].exists, !requiresDisplay, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Type"].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Choose a display first."].exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts["Enter a Lineup name."].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["lineup-editor-save"].isEnabled, file: file, line: line)
        attachEditor(app, name: "\(name) — initial setup")
    }

    private func attachEditor(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testLineupSearchFiltersAndRestoresResults() {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launch()
        XCTAssertTrue(app.buttons["Explore with Demo Data"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(app.buttons["manage-lineups"].waitForExistence(timeout: 3))
        app.buttons["manage-lineups"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.tap()
        search.typeText("  KITCHEN  ")
        XCTAssertTrue(app.buttons["lineup-card-kitchen-deck"].exists)
        search.buttons["Clear text"].tap()
        search.typeText("NoSuchLineup")
        XCTAssertFalse(app.buttons["lineup-card-kitchen-deck"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["lineup-search-empty"].exists)
        search.buttons["Clear text"].tap()
        XCTAssertTrue(app.buttons["lineup-card-kitchen-deck"].exists)
    }

    func testDailyLineupUsesFocusedScheduleDetails() {
        assertAutomatedLineupDetails(
            intent: "daily",
            expectedName: "Daily weather",
            expectedSummary: "Daily at 07:30",
            expectedDetails: ["Time", "07:30", "Days", "Weekdays"],
            screenshotName: "Daily Lineup Detail"
        )
    }

    func testIntervalLineupUsesFocusedScheduleDetails() {
        assertAutomatedLineupDetails(
            intent: "interval",
            expectedName: "News interval",
            expectedSummary: "Every 45 min",
            expectedDetails: ["Frequency", "Every 45 min", "Days", "Every day"],
            screenshotName: "Interval Lineup Detail"
        )
    }

    func testCycleLineupUsesFocusedTimingDetails() {
        assertAutomatedLineupDetails(
            intent: "cycle",
            expectedName: "Morning cycle",
            expectedSummary: "Starts at 06:00",
            expectedDetails: ["Starts each day at", "06:00", "Days", "Every day"],
            screenshotName: "Cycle Lineup Detail"
        )
    }

    private func assertAutomatedLineupDetails(
        intent: String,
        expectedName: String,
        expectedSummary: String,
        expectedDetails: [String],
        screenshotName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
        app.launchEnvironment["TESSERAE_UI_TEST_LINEUP_INTENT"] = intent
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        app.buttons["Explore with Demo Data"].tap()
        XCTAssertTrue(
            app.buttons["manage-lineups"].waitForExistence(timeout: 3),
            file: file,
            line: line
        )
        app.buttons["manage-lineups"].tap()

        let lineupCard = app.buttons["lineup-card-kitchen-deck"]
        XCTAssertTrue(lineupCard.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(lineupCard.label.contains(expectedName), file: file, line: line)
        lineupCard.tap()

        let details = app.buttons["lineup-details-disclosure"]
        XCTAssertTrue(details.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(details.label.contains(expectedSummary), file: file, line: line)
        details.tap()
        app.swipeUp()

        for expected in expectedDetails {
            let element = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS[c] %@", expected)
            ).firstMatch
            XCTAssertTrue(
                element.waitForExistence(timeout: 3),
                "Missing detail: \(expected)",
                file: file,
                line: line
            )
        }

        for hidden in ["Advance", "Trigger", "Mode", "Smart sync", "Smart sync lead"] {
            let element = app.descendants(matching: .any).matching(
                NSPredicate(format: "label == %@", hidden)
            ).firstMatch
            XCTAssertFalse(element.exists, "Unexpected detail: \(hidden)", file: file, line: line)
        }

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = screenshotName
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
