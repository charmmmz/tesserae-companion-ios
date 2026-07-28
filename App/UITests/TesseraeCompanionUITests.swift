import XCTest

final class TesseraeCompanionUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoJourneyAcrossMainTabs() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Tesserae Companion"].waitForExistence(timeout: 3))
        app.buttons["Explore with Demo Data"].tap()

        let tabBar = app.tabBars.firstMatch
        XCTAssertTrue(tabBar.buttons["Displays"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Kitchen"].exists)

        tabBar.buttons["Dashboards"].tap()
        XCTAssertTrue(app.staticTexts["Pantry"].waitForExistence(timeout: 2))

        tabBar.buttons["Send"].tap()
        app.buttons["Use Sample"].tap()
        XCTAssertTrue(app.buttons["Send to Displays"].isEnabled)
        app.buttons["Send to Displays"].tap()

        let sentAlert = app.alerts["Sent"]
        XCTAssertTrue(sentAlert.waitForExistence(timeout: 3))
        sentAlert.buttons["OK"].tap()

        tabBar.buttons["Activity"].tap()
        XCTAssertTrue(app.staticTexts["Shared Photo"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Published"].exists)
    }
}
