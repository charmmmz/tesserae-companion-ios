import XCTest

@MainActor
final class CloudBrowsingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_RUN_CLOUD_UI"] == "1",
            "Set TESSERAE_RUN_CLOUD_UI=1 with the local C1, cookie bridge and fault fixtures running.")
    }

    private func browserTrace() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_BROWSER_TRACE"], !path.isEmpty else {
            throw XCTSkip("Set TESSERAE_CLOUD_BROWSER_TRACE to the private local bridge handoff file.")
        }
        return URL(fileURLWithPath: path)
    }

    private func launch(chinese: Bool = false, accessibility: Bool = false, localPort: Int = 18765,
                        readProxy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_CLOUD_ISSUER"] = "http://127.0.0.1:8877"
        app.launchEnvironment["TESSERAE_CLOUD_BROWSER_ENTRY"] = "http://127.0.0.1:8879/begin"
        app.launchEnvironment["TESSERAE_CLOUD_TEST_NAMESPACE"] = UUID().uuidString
        app.launchEnvironment["TESSERAE_SERVER_URL"] = "http://127.0.0.1:\(localPort)"
        app.launchEnvironment["TESSERAE_PAIRING_CODE"] = "482193"
        if readProxy { app.launchEnvironment["TESSERAE_CLOUD_READ_PROXY"] = "http://127.0.0.1:8882" }
        app.launchArguments += ["-AppleLanguages", chinese ? "(zh-Hans)" : "(en)", "-AppleLocale", chinese ? "zh_CN" : "en_US"]
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }
    private func startBrowser(_ app: XCUIApplication) {
        let signIn = app.buttons["cloud-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15)); reveal(signIn, app: app); signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20))
        capture(app, "cloud-browser-consent")
    }
    private func authorize(_ app: XCUIApplication, tenant: String = "Studio A (owner)") {
        startBrowser(app)
        let allow = app.buttons["Allow"]
        app.buttons["Account"].tap()
        let choice = app.buttons[tenant]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        allow.tap()
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func selectBrowserAccount(_ account: String) async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8879/select?account=\(account)")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func fault(_ mode: String, status: Int? = nil) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8882/__control")!)
        request.httpMethod = "POST"
        var config: [String: Any] = ["mode": mode, "retry_after": 5]
        if let status { config["status"] = status }
        request.httpBody = try JSONSerialization.data(withJSONObject: config)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func waitForRecovery(_ app: XCUIApplication) {
        let problem = app.descendants(matching: .any)["cloud-read-problem"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !problem.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].exists)
    }
    func testInjectedReadStatusesAndOfflineAreActionableWithoutDeletingGrant() async throws {
        try await selectBrowserAccount("owner_a"); try await fault("pass")
        let app = launch(readProxy: true); authorize(app)
        let device = app.buttons["cloud-device-a2_shared"]
        XCTAssertTrue(device.waitForExistence(timeout: 15))
        for status in [402, 503, 429] {
            try await fault("status", status: status)
            app.buttons["cloud-refresh-list"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["cloud-read-problem"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertTrue(device.exists)
            capture(app, "cloud-injected-\(status)-kept-current-data")
            if status == 429 {
                let deadline = Date().addingTimeInterval(5)
                let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [wait], timeout: 6), .completed)
            }
            try await fault("pass")
            app.buttons["cloud-refresh-list"].firstMatch.tap(); waitForRecovery(app)
        }
        try await fault("offline")
        app.buttons["cloud-refresh-list"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloud-read-problem"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(device.exists); capture(app, "cloud-injected-offline-with-correct-tenant")
        try await fault("pass")
        app.buttons["cloud-refresh-list"].firstMatch.tap(); waitForRecovery(app)
        for status in [401, 403] {
            try await fault("status", status: status)
            app.buttons["cloud-refresh-list"].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["cloud-read-problem"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertFalse(device.exists)
            XCTAssertFalse(app.images["cloud-preview-image"].exists)
            capture(app, "cloud-injected-\(status)-private-data-hidden")
            try await fault("pass")
            app.buttons["cloud-refresh-list"].firstMatch.tap(); waitForRecovery(app)
        }
    }
    func testInjectedDetailVersionsDeletionAndForbiddenDiscardStaleImages() async throws {
        try await selectBrowserAccount("owner_a"); try await fault("pass")
        let app = launch(readProxy: true); authorize(app)
        let device = app.buttons["cloud-device-a2_shared"]
        XCTAssertTrue(device.waitForExistence(timeout: 15)); device.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        try await fault("change-device")
        app.buttons["Refresh Preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Studio A Display updated"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-injected-device-version-loaded")
        app.navigationBars.buttons["Displays"].firstMatch.tap()
        app.tabBars.buttons["Dashboards"].tap()
        let page = app.buttons["cloud-page-a2_page_shared"]
        XCTAssertTrue(page.waitForExistence(timeout: 5)); page.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        try await fault("change-page")
        app.buttons["Refresh Preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Morning Board A updated"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-injected-page-version-loaded")
        try await fault("asset404")
        app.buttons["Refresh Preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Preview Yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["cloud-preview-image"].exists)
        capture(app, "cloud-injected-404-cleared-old-image")
        try await fault("delete-page")
        app.buttons["Refresh Preview"].firstMatch.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !page.exists && app.buttons["cloud-page-a2_page_no_preview"].exists
                && !app.images["cloud-preview-image"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        capture(app, "cloud-injected-deleted-page")
        try await fault("pass")
        app.tabBars.buttons["Displays"].tap()
        XCTAssertTrue(device.waitForExistence(timeout: 5)); device.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        try await fault("status", status: 403)
        app.buttons["Refresh Preview"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloud-read-problem"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["cloud-preview-image"].exists)
        XCTAssertFalse(device.exists)
        capture(app, "cloud-injected-detail-forbidden-redacted")
        try await fault("pass")
    }
    private func chooseConnection(_ app: XCUIApplication) {
        app.buttons["root-settings"].firstMatch.tap()
        let button = app.buttons["Choose Connection"].exists ? app.buttons["Choose Connection"] : app.buttons["Other Servers"]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        XCTAssertTrue(app.navigationBars["Tesserae Connections"].waitForExistence(timeout: 5))
    }
    func testRealCloudLoginAndExistingPreviewHasNativeCloudSend() {
        let app = launch()
        authorize(app)
        let tenant = app.staticTexts["cloud-current-tenant"].firstMatch
        XCTAssertTrue(tenant.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["root-send-action"].exists)
        capture(app, "cloud-devices")
        let first = app.buttons.matching(identifier: "cloud-device-a2_shared").firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10)); first.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 15))
        capture(app, "cloud-existing-frame")
        XCTAssertEqual(app.buttons.matching(identifier: "root-settings").count, 1)
    }
    func testEmptyTenantAndMissingPreviews() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch()
        authorize(app, tenant: "Empty Home (owner)")
        XCTAssertTrue(app.staticTexts["No Cloud Displays"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["cloud-setup-link"].exists)
        capture(app, "cloud-empty-tenant")
        chooseConnection(app)
        authorize(app)
        let missing = app.buttons["cloud-device-a2_no_preview"]
        XCTAssertTrue(missing.waitForExistence(timeout: 15)); missing.tap()
        XCTAssertTrue(app.otherElements["cloud-no-preview"].waitForExistence(timeout: 10)
            || app.staticTexts["No Preview Yet"].exists)
        capture(app, "cloud-no-frame")
        app.navigationBars.buttons["Displays"].firstMatch.tap()
        app.tabBars.buttons["Dashboards"].tap()
        let page = app.buttons["cloud-page-a2_page_no_preview"]
        XCTAssertTrue(page.waitForExistence(timeout: 5)); page.tap()
        XCTAssertTrue(app.staticTexts["No Preview Yet"].waitForExistence(timeout: 10))
        capture(app, "cloud-no-thumbnail")
    }
    func testSameResourceIDsSwitchBetweenAccountsWithoutOldPrivateData() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch(); authorize(app)
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 15))
        chooseConnection(app)
        try await selectBrowserAccount("owner_b")
        authorize(app, tenant: "Studio B (owner)")
        XCTAssertTrue(app.staticTexts["Studio B"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Studio A Display"].exists)
        app.buttons["cloud-device-a2_shared"].tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-account-b-frame")
        chooseConnection(app)
        let savedA = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-connection-' AND label CONTAINS 'Studio A'")).firstMatch
        XCTAssertTrue(savedA.waitForExistence(timeout: 5)); reveal(savedA, app: app); savedA.tap()
        XCTAssertTrue(app.staticTexts["Studio A Display"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Studio B Display"].exists)
        capture(app, "cloud-returned-account-a")
        try await selectBrowserAccount("owner_a")
    }
    func testChineseLargestAccessibilityLayout() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch(chinese: true, accessibility: true)
        authorize(app)
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["root-send-action"].exists)
        capture(app, "cloud-chinese-ax5-list")
        app.buttons["cloud-device-a2_shared"].tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-chinese-ax5-detail")
        XCTAssertEqual(app.buttons.matching(identifier: "root-settings").count, 1)
        app.buttons["root-settings"].firstMatch.tap()
        reveal(app.buttons["选择连接"], app: app)
        app.buttons["选择连接"].tap()
        XCTAssertTrue(app.navigationBars["Tesserae 连接"].waitForExistence(timeout: 5))
        capture(app, "cloud-chinese-connections")
    }
    private func connectManual(_ app: XCUIApplication) {
        let manual = app.buttons["Enter Server Address"]
        XCTAssertTrue(manual.waitForExistence(timeout: 10)); reveal(manual, app: app); manual.tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 5))
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["display-card-picpak-kitchen"].waitForExistence(timeout: 25))
        XCTAssertFalse(app.alerts["Something Went Wrong"].exists)
    }
    func testSavedLocalConnectionReturnsWithoutPairingAgain() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch()
        connectManual(app)
        capture(app, "a2-local-before-cloud")
        chooseConnection(app)
        authorize(app)
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 15))
        chooseConnection(app)
        let home = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-connection-' AND label CONTAINS 'Home'")).firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5)); reveal(home, app: app); home.tap()
        XCTAssertTrue(app.buttons["display-card-picpak-kitchen"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["Pairing code"].exists)
        XCTAssertTrue(app.buttons["root-send-action"].exists)
        capture(app, "a2-saved-local-restored")
    }
    func testChooseConnectionManualLocalWithDelayedFirstRead() {
        let app = launch(localPort: 18766)
        let demo = app.buttons["Explore with Demo Data"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10)); reveal(demo, app: app); demo.tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 30))
        chooseConnection(app)
        connectManual(app)
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        capture(app, "a2-delayed-local-list")
    }
    func testBonjourConnectsActualLoopbackFixture() {
        let app = launch()
        let server = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tesserae A2 Fixture'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        reveal(server, app: app); server.tap()
        XCTAssertTrue(app.textFields["Pairing code"].waitForExistence(timeout: 5))
        app.buttons["Connect"].tap()
        XCTAssertTrue(app.buttons["display-card-picpak-kitchen"].waitForExistence(timeout: 25))
        capture(app, "a2-bonjour-local-list")
    }
    func testExternalSafariCompletesOriginalPendingAuthorization() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch()
        startBrowser(app)
        let trace = try browserTrace()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: trace)) as? [String: Any]
        guard let raw = object?["url"] as? String, let url = URL(string: raw) else {
            XCTFail("Missing private browser handoff fixture"); return
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.open(url)
        let allow = safari.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20))
        safari.buttons["Account"].tap()
        safari.buttons["Studio A (owner)"].tap()
        capture(safari, "cloud-external-browser-consent")
        allow.tap()
        let open = safari.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 20))
        capture(app, "cloud-external-callback-completed")
    }
    func testPendingLoginSurvivesProcessTerminationBeforeExternalCallback() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch()
        startBrowser(app)
        let trace = try browserTrace()
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: trace)) as? [String: Any]
        guard let raw = object?["url"] as? String, let url = URL(string: raw) else {
            XCTFail("Missing private browser handoff fixture"); return
        }
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["cloud-signin-progress"].firstMatch.waitForExistence(timeout: 10))
        capture(app, "cloud-pending-restored-after-termination")
        safari.open(url)
        XCTAssertTrue(safari.buttons["Allow"].waitForExistence(timeout: 20))
        safari.buttons["Account"].tap()
        safari.buttons["Studio A (owner)"].tap()
        safari.buttons["Allow"].tap()
        let open = safari.buttons["Open"]
        if open.waitForExistence(timeout: 2) { open.tap() }
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 20))
        capture(app, "cloud-terminated-pending-external-callback")
    }
    func testUnknownPendingCallbackShowsRecoveryWithoutLosingDemo() {
        let app = launch()
        let demo = app.buttons["Explore with Demo Data"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10)); reveal(demo, app: app); demo.tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 30))
        XCUIDevice.shared.system.open(URL(string: "com.charmmmz.tesseraecompanion:/oauth/callback?state=another-device&code=synthetic-invalid")!)
        XCTAssertTrue(app.descendants(matching: .any)["cloud-authorization-message"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["root-send-action"].exists)
        capture(app, "cloud-unknown-callback-kept-demo")
    }
    func testCloudColdAndTwentyWarmListPresentations() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch(); startBrowser(app)
        app.buttons["Account"].tap(); app.buttons["Studio A (owner)"].tap()
        let start = ProcessInfo.processInfo.systemUptime
        app.buttons["Allow"].tap()
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 15))
        var samples: [[String: Any]] = [["kind": "cold", "sample": 0,
            "seconds": ProcessInfo.processInfo.systemUptime - start, "success": true]]
        for index in 0..<20 {
            let pages = index.isMultiple(of: 2)
            let start = ProcessInfo.processInfo.systemUptime
            app.tabBars.buttons[pages ? "Dashboards" : "Displays"].tap()
            let ready = app.buttons[pages ? "cloud-page-a2_page_shared" : "cloud-device-a2_shared"].waitForExistence(timeout: 5)
            let sample: [String: Any] = ["kind": "warm", "sample": index,
                "seconds": ProcessInfo.processInfo.systemUptime - start, "success": ready]
            XCTAssertTrue(ready); samples.append(sample)
        }
        print("A2_CLOUD_PERF " + String(decoding: try JSONSerialization.data(withJSONObject: samples, options: .sortedKeys), as: UTF8.self))
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        attachment.name = "cloud-list-raw-samples"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testReviewWalkthrough() async throws {
        try await selectBrowserAccount("owner_a")
        let app = launch(); authorize(app)
        let device = app.buttons["cloud-device-a2_shared"]
        XCTAssertTrue(device.waitForExistence(timeout: 15)); device.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "review-native-cloud-frame")
        app.navigationBars.buttons["Displays"].firstMatch.tap()
        for _ in 0..<2 {
            app.tabBars.buttons["Dashboards"].tap()
            XCTAssertTrue(app.buttons["cloud-page-a2_page_shared"].waitForExistence(timeout: 5))
            app.tabBars.buttons["Displays"].tap()
            XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 5))
        }
        app.tabBars.buttons["Dashboards"].tap()
        app.buttons["cloud-page-a2_page_shared"].tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "review-native-cloud-dashboard")
        app.buttons["root-settings"].firstMatch.tap()
        app.buttons["Cloud Usage & Features"].tap()
        XCTAssertTrue(app.navigationBars["Cloud Usage & Features"].waitForExistence(timeout: 5))
        app.swipeUp(); app.swipeDown()
        capture(app, "review-native-cloud-usage")
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.buttons["root-send-action"].exists)
    }
    func testCancelSystemBrowserPreservesDemoConnection() {
        let app = launch()
        let demo = app.buttons["Explore with Demo Data"]
        XCTAssertTrue(demo.waitForExistence(timeout: 10)); reveal(demo, app: app); demo.tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 30))
        app.buttons["root-settings"].firstMatch.tap()
        app.buttons["choose-connection"].tap()
        let signIn = app.buttons["cloud-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10)); reveal(signIn, app: app); signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        XCTAssertTrue(app.buttons["Allow"].waitForExistence(timeout: 20))
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() } else { app.buttons["Deny"].tap() }
        XCTAssertTrue(app.buttons["cloud-signin"].waitForExistence(timeout: 10))
        capture(app, "cloud-login-canceled")
        app.buttons["Cancel"].firstMatch.tap()
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 10))
    }
}
