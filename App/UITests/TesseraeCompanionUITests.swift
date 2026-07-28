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
        XCTAssertTrue(app.staticTexts["Connected through Companion API"].exists)
    }
}
