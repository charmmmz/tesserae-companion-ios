import XCTest

@MainActor
final class ConnectionPerformanceUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_RUN_CONNECTION_PERF"] == "1",
            "Set TESSERAE_RUN_CONNECTION_PERF=1 with both simulator bundles and the local fixture prepared.")
    }

    private func runLocal(_ variant: String, sample: Int) -> [String: Any] {
        let app = variant == "baseline"
            ? XCUIApplication(bundleIdentifier: "com.charmmmz.tesseraecompanion.baseline") : XCUIApplication()
        app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
        app.launchEnvironment["TESSERAE_SERVER_URL"] = "http://127.0.0.1:18765"
        app.launchEnvironment["TESSERAE_PAIRING_CODE"] = "482193"
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        if variant == "head" {
            let selfHosted = app.segmentedControls["connection-type"].buttons["Self-Hosted"]
            XCTAssertTrue(selfHosted.waitForExistence(timeout: 10))
            selfHosted.tap()
        }
        let manual = app.buttons["Enter Server Address"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if manual.isHittable { break }
            app.swipeUp()
        }
        manual.tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 5))
        let start = ProcessInfo.processInfo.systemUptime
        app.buttons["Connect"].tap()
        let row = app.buttons["display-card-picpak-kitchen"]
        let success = row.waitForExistence(timeout: 20)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(success)
        XCTAssertFalse(app.alerts["Something Went Wrong"].exists)
        if sample == 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "perf-\(variant)-actual-list"; attachment.lifetime = .keepAlways; add(attachment)
        }
        app.terminate()
        return ["variant": variant, "sample": sample, "seconds": elapsed, "success": success]
    }
    func testTwentyInterleavedLocalListLoads() throws {
        var samples: [[String: Any]] = []
        for index in 0..<20 {
            for variant in index.isMultiple(of: 2) ? ["baseline", "head"] : ["head", "baseline"] {
                let sample = runLocal(variant, sample: index)
                samples.append(sample)
                let data = try JSONSerialization.data(withJSONObject: sample, options: .sortedKeys)
                print("A2_PERF " + String(decoding: data, as: UTF8.self))
            }
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        attachment.name = "local-list-raw-samples"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
