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
    private func fault(_ mode: String, status: Int? = nil, retryAfter: Int = 5) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8882/__control")!)
        request.httpMethod = "POST"
        var config: [String: Any] = ["mode": mode, "retry_after": retryAfter]
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
    func testDetailRecoversFromRateLimitedListAndSeparatesReloadFromRegenerate() async throws {
        try await selectBrowserAccount("owner_a")
        try await fault("pass")
        let app = launch(readProxy: true)
        authorize(app)
        let device = app.buttons["cloud-device-a2_shared"]
        XCTAssertTrue(device.waitForExistence(timeout: 15))

        try await fault("status", status: 429, retryAfter: 10)
        app.buttons["cloud-refresh-list"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["cloud-read-problem"].firstMatch.waitForExistence(timeout: 5))
        device.tap()
        XCTAssertTrue(app.staticTexts["Preview Temporarily Unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Loading Preview…"].exists)
        let waitingReload = app.buttons["cloud-reload-preview"].firstMatch
        XCTAssertTrue(waitingReload.exists)
        XCTAssertFalse(waitingReload.isEnabled)
        capture(app, "cloud-preview-rate-limited")
        try await fault("pass")
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 15))
        capture(app, "cloud-preview-recovered-automatically")

        let reload = app.buttons["cloud-reload-preview"].firstMatch
        let regenerate = app.buttons["cloud-refresh-current"]
        XCTAssertEqual(reload.label, "Reload Preview")
        reveal(regenerate, app: app)
        XCTAssertEqual(regenerate.label, "Regenerate Display Frame")
        XCTAssertGreaterThanOrEqual(regenerate.frame.height, 44)
        XCTAssertGreaterThan(regenerate.frame.minY, app.images["cloud-preview-image"].frame.minY)
        capture(app, "cloud-display-preview-actions")
        reload.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.navigationBars["Send Result"].exists)
        reveal(regenerate, app: app)
        regenerate.tap()
        XCTAssertTrue(app.buttons["cloud-result-target-a2_shared"].waitForExistence(timeout: 12))
        capture(app, "cloud-regenerate-result")
    }

    func testComposerRequiresSelectionWhenAllSavedDisplaysDisappear() async throws {
        try await selectBrowserAccount("owner_a")
        try await fault("pass")
        let app = launch(readProxy: true)
        authorize(app)
        let original = app.buttons["send-display-a2_shared"]
        let replacement = app.buttons["send-display-a2_no_preview"]
        let send = app.buttons["root-send-action"].firstMatch
        XCTAssertTrue(send.waitForExistence(timeout: 15))
        send.tap()
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let originalReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in original.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [originalReady], timeout: 5), .completed)
        if original.isSelected { original.tap() }
        original.tap()
        XCTAssertTrue(original.isSelected)
        XCTAssertFalse(replacement.isSelected)
        app.buttons["root-send-close"].tap()

        try await fault("delete-device")
        app.buttons["cloud-refresh-list"].firstMatch.tap()
        let originalRow = app.buttons["cloud-device-a2_shared"]
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !originalRow.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 8), .completed)
        send.tap()
        XCTAssertTrue(app.staticTexts["cloud-send-saved-displays-unavailable"].waitForExistence(timeout: 5))
        XCTAssertFalse(original.exists)
        XCTAssertFalse(replacement.isSelected)
        capture(app, "cloud-send-no-replacement-selected")
        app.descendants(matching: .any)["selected-image-preview"].firstMatch.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8), "Seed the test simulator photo library with a fixture image.")
        photo.tap()
        XCTAssertTrue(app.buttons["send-change-photo"].waitForExistence(timeout: 8))
        let submit = app.buttons["send-submit"]
        XCTAssertFalse(submit.isEnabled)
        reveal(replacement, app: app)
        replacement.tap()
        XCTAssertTrue(replacement.isSelected)
        let canSend = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in submit.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [canSend], timeout: 8), .completed)
        XCTAssertFalse(app.staticTexts["cloud-send-saved-displays-unavailable"].exists)
        try await fault("pass")
    }

    func testInjectedDetailVersionsDeletionAndForbiddenDiscardStaleImages() async throws {
        try await selectBrowserAccount("owner_a"); try await fault("pass")
        let app = launch(readProxy: true); authorize(app)
        let device = app.buttons["cloud-device-a2_shared"]
        XCTAssertTrue(device.waitForExistence(timeout: 15)); device.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        try await fault("change-device")
        app.buttons["cloud-reload-preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Studio A Display updated"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-injected-device-version-loaded")
        app.navigationBars.buttons["Displays"].firstMatch.tap()
        app.tabBars.buttons["Dashboards"].tap()
        let page = app.buttons["cloud-page-a2_page_shared"]
        XCTAssertTrue(page.waitForExistence(timeout: 5)); page.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        try await fault("change-page")
        app.buttons["cloud-reload-preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Morning Board A updated"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-injected-page-version-loaded")
        try await fault("asset404")
        app.buttons["cloud-reload-preview"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Preview Yet"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.images["cloud-preview-image"].exists)
        capture(app, "cloud-injected-404-cleared-old-image")
        try await fault("delete-page")
        app.buttons["cloud-reload-preview"].firstMatch.tap()
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
        app.buttons["cloud-reload-preview"].firstMatch.tap()
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
        let selfHosted = app.segmentedControls["connection-type"].buttons["自建"]
        XCTAssertTrue(selfHosted.waitForExistence(timeout: 5))
        selfHosted.tap()
        let manual = app.buttons["输入服务器地址"]
        reveal(manual, app: app)
        XCTAssertGreaterThanOrEqual(manual.frame.height, 44)
        capture(app, "self-hosted-chinese-ax5")
        let cloud = app.segmentedControls["connection-type"].buttons["云端"]
        if !cloud.isHittable { app.swipeDown() }
        cloud.tap()
        authorize(app)
        XCTAssertTrue(app.buttons["cloud-device-a2_shared"].waitForExistence(timeout: 15))
        capture(app, "cloud-chinese-ax5-list")
        app.buttons["cloud-device-a2_shared"].tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "cloud-chinese-ax5-detail")
        XCTAssertEqual(app.buttons.matching(identifier: "root-settings").count, 1)
        app.buttons["root-settings"].firstMatch.tap()
        let cloudAccount = app.buttons["cloud-account-settings"]
        reveal(cloudAccount, app: app)
        cloudAccount.tap()
        XCTAssertTrue(app.navigationBars["云端账号"].waitForExistence(timeout: 5))
        capture(app, "cloud-chinese-account")
        app.navigationBars.buttons["设置"].firstMatch.tap()
        let choose = app.buttons["choose-connection"]
        reveal(choose, app: app)
        choose.tap()
        XCTAssertTrue(app.navigationBars["Tesserae 连接"].waitForExistence(timeout: 5))
        capture(app, "cloud-chinese-connections")
    }
    private func showSelfHosted(_ app: XCUIApplication) {
        let selfHosted = app.segmentedControls["connection-type"].buttons["Self-Hosted"]
        XCTAssertTrue(selfHosted.waitForExistence(timeout: 10))
        reveal(selfHosted, app: app)
        selfHosted.tap()
    }
    private func connectManual(_ app: XCUIApplication) {
        showSelfHosted(app)
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
        let demo = app.onboardingShortcut("onboarding-demo")
        XCTAssertTrue(demo.waitForExistence(timeout: 10)); reveal(demo, app: app); demo.tap()
        XCTAssertTrue(app.buttons["root-send-action"].waitForExistence(timeout: 30))
        chooseConnection(app)
        connectManual(app)
        XCTAssertFalse(app.navigationBars["Settings"].exists)
        capture(app, "a2-delayed-local-list")
    }
    func testBonjourConnectsActualLoopbackFixture() {
        let app = launch()
        showSelfHosted(app)
        app.buttons["onboarding-more"].tap()
        let manual = app.buttons["Enter Server Address"]
        let loading = app.descendants(matching: .any)["self-hosted-discovery-loading"]
        XCTAssertTrue(loading.exists)
        capture(app, "self-hosted-searching")
        XCTAssertTrue(manual.isHittable)
        var previousFrame = CGRect.null
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let currentFrame = manual.frame
            defer { previousFrame = currentFrame }
            return abs(currentFrame.minY - previousFrame.minY) < 0.5
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 3), .completed)
        let manualDuringSearch = manual.frame
        let server = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tesserae A2 Fixture'")).firstMatch
        XCTAssertTrue(server.waitForExistence(timeout: 20))
        capture(app, "self-hosted-server-found")
        XCTAssertFalse(loading.exists)
        XCTAssertEqual(manual.frame.minY, manualDuringSearch.minY, accuracy: 1)
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
        let demo = app.onboardingShortcut("onboarding-demo")
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
        let account = app.buttons["cloud-account-settings"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["choose-connection"].exists)
        XCTAssertFalse(app.buttons["cloud-signin"].exists)
        capture(app, "review-cloud-settings")
        account.tap()
        XCTAssertTrue(app.navigationBars["Cloud Account"].waitForExistence(timeout: 5))
        capture(app, "review-cloud-account")
        let workspace = app.descendants(matching: .any)["cloud-account-workspace"].firstMatch
        let email = app.descendants(matching: .any)["cloud-account-email"].firstMatch
        XCTAssertTrue(workspace.exists)
        XCTAssertTrue(email.exists)
        let signOut = app.buttons["cloud-sign-out"]
        reveal(signOut, app: app)
        signOut.tap()
        let cancelSignOut = app.alerts["Sign Out of Cloud?"].buttons["Cancel"]
        XCTAssertTrue(cancelSignOut.waitForExistence(timeout: 5))
        cancelSignOut.tap()
        XCTAssertTrue(app.navigationBars["Cloud Account"].exists)
        app.buttons["Cloud Usage & Features"].tap()
        XCTAssertTrue(app.navigationBars["Cloud Usage & Features"].waitForExistence(timeout: 5))
        let limits = app.buttons["Limits"]
        reveal(limits, app: app)
        limits.tap()
        let dailyRenders = app.descendants(matching: .any)["cloud-limit-renders_per_day"].firstMatch
        reveal(dailyRenders, app: app)
        XCTAssertTrue(dailyRenders.exists)
        capture(app, "review-native-cloud-usage")
        app.navigationBars.buttons["Cloud Account"].firstMatch.tap()
        app.navigationBars.buttons["Settings"].firstMatch.tap()
        app.buttons["choose-connection"].tap()
        XCTAssertTrue(app.navigationBars["Tesserae Connections"].waitForExistence(timeout: 5))
        capture(app, "review-cloud-connections")
        app.navigationBars.buttons["Cancel"].tap()
        account.tap()
        reveal(signOut, app: app)
        signOut.tap()
        let confirm = app.alerts["Sign Out of Cloud?"].buttons["Sign Out"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.buttons["cloud-signin"].waitForExistence(timeout: 8))
    }
    func testCancelSystemBrowserPreservesDemoConnection() {
        let app = launch()
        let demo = app.onboardingShortcut("onboarding-demo")
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
