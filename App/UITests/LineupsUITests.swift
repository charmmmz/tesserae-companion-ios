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
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 2))
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

        XCTAssertFalse(app.buttons["lineup-editor-displays"].exists)
        app.buttons["lineup-editor-dashboards"].tap()
        let search = app.searchFields.firstMatch
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
            expectedSummary: "Resets at 06:00",
            expectedDetails: ["Daily reset", "06:00", "Days", "Every day"],
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
