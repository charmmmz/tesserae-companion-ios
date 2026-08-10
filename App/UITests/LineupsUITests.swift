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

        let lineupsTab = app.tabBars.firstMatch.buttons["Lineups"]
        XCTAssertTrue(lineupsTab.waitForExistence(timeout: 3))
        lineupsTab.tap()

        let lineupCard = app.buttons["lineup-card-kitchen-deck"]
        XCTAssertTrue(lineupCard.waitForExistence(timeout: 3))
        XCTAssertTrue(lineupCard.label.contains("Kitchen deck"))
        lineupCard.tap()

        let enabledControl = app.buttons["lineup-enabled-control"]
        XCTAssertTrue(enabledControl.waitForExistence(timeout: 3))
        XCTAssertEqual(enabledControl.label, "Disable")

        let kitchenTarget = app.buttons["lineup-target-picpak-kitchen"]
        XCTAssertTrue(kitchenTarget.exists)
        XCTAssertTrue(app.buttons["lineup-next"].isEnabled)

        enabledControl.tap()
        let enableLabel = NSPredicate(format: "label == 'Enable'")
        expectation(for: enableLabel, evaluatedWith: enabledControl)
        waitForExpectations(timeout: 3)

        enabledControl.tap()
        let disableLabel = NSPredicate(format: "label == 'Disable'")
        expectation(for: disableLabel, evaluatedWith: enabledControl)
        waitForExpectations(timeout: 3)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Lineup Detail"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
