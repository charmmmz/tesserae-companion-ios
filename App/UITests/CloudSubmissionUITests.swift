import XCTest

@MainActor final class CloudSubmissionUITests: XCTestCase {
    private var launchStarted: ContinuousClock.Instant?
    private var launchReturned: ContinuousClock.Instant?
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_RUN_CLOUD_SUBMISSION_UI"] == "1",
            "Opt in with the owned A3 C1 fixture, browser bridge and seeded marker photo.")
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TESSERAE_CLOUD_ISSUER"] = "http://127.0.0.1:8877"
        app.launchEnvironment["TESSERAE_CLOUD_BROWSER_ENTRY"] = "http://127.0.0.1:8879/begin"
        let namespace = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_EXISTING_NAMESPACE"] ?? UUID().uuidString
        app.launchEnvironment["TESSERAE_CLOUD_TEST_NAMESPACE"] = namespace
        print("A3_UI_NAMESPACE \(namespace)")
        let chinese = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_LANGUAGE"] == "zh"
        app.launchArguments += ["-AppleLanguages", chinese ? "(zh-Hans)" : "(en)", "-AppleLocale", chinese ? "zh_CN" : "en_US"]
        if ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_AX"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        if ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_SUBMISSION_PROXY"] == "1" {
            app.launchEnvironment["TESSERAE_CLOUD_SUBMISSION_PROXY"] = "http://127.0.0.1:8882"
        }
        launchStarted = .now
        app.launch()
        launchReturned = .now
        return app
    }
    private func authorize(_ app: XCUIApplication, account: String = "owner_a", tenantName: String = "A3 Studio A (owner)") async throws {
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8879/select?account=\(account)")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let signIn = app.buttons["cloud-signin"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15)); reveal(signIn, in: app); signIn.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let consent = springboard.buttons["Continue"]
        if consent.waitForExistence(timeout: 3) { consent.tap() }
        let allow = app.buttons["Allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 20))
        app.buttons["Account"].tap()
        let tenant = app.buttons[tenantName]
        XCTAssertTrue(tenant.waitForExistence(timeout: 5)); tenant.tap(); allow.tap()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            let exists = element.exists
            if exists && element.isHittable { return }
            let region = exists ? app.scrollViews.containing(.any, identifier: element.identifier).allElementsBoundByIndex.last : nil
            let surface: XCUIElement = region ?? app
            let above = exists && element.frame.midY < surface.frame.midY
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: above ? 0.25 : 0.8))
            start.press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: above ? 0.8 : 0.25)))
        }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    func testMarkerSendScreenPreviewsAndDurableResult() async throws {
        let app = launch()
        try await authorize(app)
        app.buttons["root-send-action"].firstMatch.tap()
        let land = app.buttons["send-display-a3_land"], portrait = app.buttons["send-display-a3_portrait"]
        XCTAssertTrue(land.waitForExistence(timeout: 8))
        let selected = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'send-display-'"))
            .allElementsBoundByIndex.filter(\.isSelected)
        XCTAssertEqual(selected.count, 1)
        reveal(portrait, in: app); if !portrait.isSelected { portrait.tap() }
        let picker = app.buttons["send-preview-display-picker"]
        reveal(picker, in: app); picker.tap()
        app.buttons["send-preview-display-a3_portrait"].tap()
        capture(app, "A3-portrait-preview-before-photo")
        let canvas = app.descendants(matching: .any)["selected-image-preview"].firstMatch
        reveal(canvas, in: app); canvas.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,' OR label BEGINSWITH '照片,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8)); photo.tap()
        let submit = app.buttons["send-submit"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in submit.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let zoom = app.staticTexts["send-framing-zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        let initialZoom = zoom.label
        canvas.pinch(withScale: 1.5, velocity: 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.45)))
        let portraitZoom = zoom.label
        capture(app, "A3-after-portrait-pinch-and-drag")
        XCTAssertNotEqual(portraitZoom, initialZoom)
        capture(app, "A3-photo-confirmed-portrait-manual-crop")
        picker.tap(); app.buttons["send-preview-display-a3_land"].tap()
        XCTAssertNotEqual(zoom.label, portraitZoom)
        capture(app, "A3-photo-confirmed-landscape")
        picker.tap(); app.buttons["send-preview-display-a3_portrait"].tap()
        XCTAssertEqual(zoom.label, portraitZoom)
        capture(app, "A3-portrait-crop-preserved-after-switch")
        submit.tap()
        XCTAssertTrue(app.buttons["cloud-result-target-a3_land"].waitForExistence(timeout: 15))
        reveal(app.buttons["cloud-result-target-a3_portrait"], in: app)
        XCTAssertTrue(app.buttons["cloud-result-target-a3_portrait"].exists)
        let generatedLabel = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_LANGUAGE"] == "zh" ? "画面已生成" : "Frame Generated"
        let portraitResult = app.buttons["cloud-result-target-a3_portrait"]
        let generated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in portraitResult.label.contains(generatedLabel) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [generated], timeout: 20), .completed)
        capture(app, "A3-generated-results")
        let previewPicker = app.buttons["cloud-result-preview-picker"]
        reveal(previewPicker, in: app)
        XCTAssertTrue(previewPicker.waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["cloud-send-results"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8)); result.tap()
        XCTAssertTrue(app.buttons["cloud-result-target-a3_land"].waitForExistence(timeout: 8))
        capture(app, "A3-restored-result-no-resend")
    }
    func testRestoreAcceptedResultWithoutSending() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_EXISTING_NAMESPACE"] != nil,
            "Provide the namespace of an already accepted real Cloud send.")
        let app = launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["cloud-send-results"].firstMatch.tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 8)); entry.tap()
        let land = app.buttons["cloud-result-target-a3_land"], portrait = app.buttons["cloud-result-target-a3_portrait"]
        reveal(land, in: app); XCTAssertTrue(land.exists)
        reveal(portrait, in: app); XCTAssertTrue(portrait.exists)
        capture(app, "A3-durable-per-device-generated-results")
        XCTAssertFalse(land.isSelected); XCTAssertFalse(portrait.isSelected)
        let preview = app.buttons["cloud-result-preview-picker"]
        reveal(preview, in: app); preview.buttons.firstMatch.tap()
        app.buttons["Landscape A"].tap()
        XCTAssertTrue(preview.label.contains("Landscape A"))
        capture(app, "A3-frozen-landscape-result-preview")
        reveal(land, in: app); land.tap()
        XCTAssertTrue(land.isSelected)
        reveal(preview, in: app); preview.buttons.firstMatch.tap(); app.buttons["Portrait A"].tap()
        XCTAssertTrue(preview.label.contains("Portrait A"))
        reveal(land, in: app)
        XCTAssertTrue(land.isSelected); XCTAssertFalse(portrait.isSelected)
        capture(app, "A3-preview-switch-independent-of-resend-selection")
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["cloud-send-results"].firstMatch.tap()
        let restored = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-'")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 8)); restored.tap()
        reveal(app.buttons["cloud-result-target-a3_land"], in: app)
        capture(app, "A3-restarted-durable-result-without-replay")
    }

    func testBrowseOtherDashboardAndRefreshCurrentPage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_EXISTING_NAMESPACE"] != nil)
        let app = launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        let dashboards = app.buttons["Dashboards"].firstMatch
        dashboards.tap()
        let other = app.buttons["cloud-page-a3_page_portrait"]
        XCTAssertTrue(other.waitForExistence(timeout: 8)); other.tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["cloud-refresh-current"].exists)
        capture(app, "A3-other-dashboard-read-only")
        app.navigationBars.buttons.firstMatch.tap()
        app.buttons["Displays"].firstMatch.tap()
        app.buttons["cloud-device-a3_land"].tap()
        let refresh = app.buttons["cloud-refresh-current"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10)); refresh.tap()
        let result = app.buttons["cloud-result-target-a3_land"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let generated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in result.label.contains("Frame Generated") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [generated], timeout: 20), .completed)
        capture(app, "A3-current-bound-page-generated-result")
    }

    private func prepareMarker(_ app: XCUIApplication, targets: Set<String>) {
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["root-send-action"].firstMatch.tap()
        let canvas = app.descendants(matching: .any)["selected-image-preview"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5)); canvas.tap()
        let photo = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Photo,' OR label BEGINSWITH '照片,'")).firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 8)); photo.tap()
        for id in ["a3_land", "a3_portrait", "a3_large", "a3_native", "a3_unbound"] {
            let row = app.buttons["send-display-\(id)"]
            reveal(row, in: app)
            if row.isSelected != targets.contains(id) { row.tap() }
        }
        let submit = app.buttons["send-submit"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in submit.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
    private func assertOutcome(_ title: String, device: String, in app: XCUIApplication) {
        let result = app.buttons["cloud-result-target-\(device)"]
        reveal(result, in: app)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in result.label.contains(title) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 20), .completed)
    }
    func testPartialResponseStopsLaterUpload() throws {
        let app = launch()
        prepareMarker(app, targets: ["a3_land", "a3_native", "a3_large"])
        capture(app, "A3-partial-three-targets-before-submit")
        app.buttons["send-submit"].tap()
        assertOutcome("Frame Generated", device: "a3_land", in: app)
        assertOutcome("Not Sent", device: "a3_large", in: app)
        assertOutcome("Outcome Unknown", device: "a3_native", in: app)
        XCTAssertFalse(app.buttons["cloud-result-target-a3_land"].isSelected)
        XCTAssertTrue(app.buttons["cloud-result-target-a3_native"].isSelected)
        capture(app, "A3-real-partial-generated-unknown-unstarted")
    }
    func testStructuredQuotaRefusal() throws {
        let app = launch()
        prepareMarker(app, targets: ["a3_land"])
        app.buttons["send-submit"].tap()
        assertOutcome("Cloud Plan Limit Reached", device: "a3_land", in: app)
        capture(app, "A3-real-quota-refusal")
    }

    private func openSavedResult(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["cloud-send-results"].firstMatch.tap()
        let entry: XCUIElement
        if let id = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"] {
            entry = app.buttons["cloud-result-\(id)"]
        } else { entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-'")).firstMatch }
        reveal(entry, in: app)
        XCTAssertTrue(entry.exists); entry.tap()
    }
    func testResponseLossStaysUnknownAfterRestart() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_SUBMISSION_PROXY"] == "1")
        let app = launch(); prepareMarker(app, targets: ["a3_land"])
        app.buttons["send-submit"].tap()
        assertOutcome("Outcome Unknown", device: "a3_land", in: app)
        capture(app, "A3-real-response-loss-unknown")
        app.terminate(); app.launch(); openSavedResult(app)
        assertOutcome("Outcome Unknown", device: "a3_land", in: app)
        capture(app, "A3-response-loss-restart-no-replay")
    }
    func testExplicitUnknownResendSelectedTargetOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"] != nil)
        let app = launch(); openSavedResult(app)
        assertOutcome("Outcome Unknown", device: "a3_native", in: app)
        let land = app.buttons["cloud-result-target-a3_land"]
        XCTAssertFalse(land.isSelected)
        let large = app.buttons["cloud-result-target-a3_large"]
        if large.isSelected { large.tap() }
        let native = app.buttons["cloud-result-target-a3_native"]
        XCTAssertTrue(native.isSelected)
        let resend = app.buttons["cloud-result-resend"]; reveal(resend, in: app); resend.tap()
        let confirm = app.buttons["cloud-result-confirm-resend"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        capture(app, "A3-unknown-explicit-duplicate-confirmation")
        confirm.tap()
        assertOutcome("Frame Generated", device: "a3_native", in: app)
        XCTAssertFalse(app.buttons["cloud-result-target-a3_land"].exists)
        XCTAssertFalse(app.buttons["cloud-result-target-a3_large"].exists)
        capture(app, "A3-manual-resend-only-selected-native")
    }
    func testDeleteSavedPhotoAndResult() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"] != nil)
        let app = launch(); openSavedResult(app)
        let photo = app.images["cloud-submitted-photo"]
        XCTAssertTrue(photo.waitForExistence(timeout: 5))
        let removePhoto = app.buttons["cloud-result-delete-photo"]; reveal(removePhoto, in: app); removePhoto.tap()
        let confirmPhoto = app.buttons["cloud-result-confirm-delete-photo"].firstMatch
        XCTAssertTrue(confirmPhoto.waitForExistence(timeout: 5)); confirmPhoto.tap()
        XCTAssertTrue(app.staticTexts["cloud-result-media-expired"].waitForExistence(timeout: 5))
        XCTAssertFalse(photo.exists); XCTAssertFalse(app.buttons["cloud-result-resend"].isEnabled)
        capture(app, "A3-deleted-photo-no-preview-or-resend")
        let remove = app.buttons["cloud-result-delete-result"]; reveal(remove, in: app); remove.tap()
        let confirm = app.buttons["cloud-result-confirm-delete-result"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        let id = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"]!
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["cloud-result-\(id)"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
        capture(app, "A3-deleted-result-closed-history")
    }
    private func chooseConnection(_ app: XCUIApplication) {
        app.buttons["root-settings"].firstMatch.tap()
        let choose = app.buttons["Choose Connection"].firstMatch
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        XCTAssertTrue(app.navigationBars["Tesserae Connections"].waitForExistence(timeout: 5))
    }
    func testSameDeviceIDsAccountSwitchHidesSavedResults() async throws {
        let app = launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        if !app.staticTexts["cloud-current-tenant"].firstMatch.label.contains("A3 Studio B") {
            chooseConnection(app)
            try await authorize(app, account: "owner_b", tenantName: "A3 Studio B (owner)")
        }
        let current = app.staticTexts["cloud-current-tenant"].firstMatch
        let switched = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in current.label.contains("A3 Studio B") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 10), .completed)
        app.buttons["cloud-send-results"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["No Cloud Send Results"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.images["cloud-submitted-photo"].exists)
        capture(app, "A3-account-b-cannot-see-a-results")
        app.buttons["cloud-results-close"].tap(); chooseConnection(app)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'saved-connection-' AND label CONTAINS 'A3 Studio A'")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); reveal(saved, in: app); saved.tap()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        openSavedResult(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-target-'")).firstMatch.waitForExistence(timeout: 8))
        capture(app, "A3-return-account-a-original-result")
    }

    func testLogoutReloginShowsOriginalIdentityHistoryWithoutResending() async throws {
        let app = launch()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        app.buttons["root-settings"].firstMatch.tap()
        let signOut = app.buttons["Sign Out"]; reveal(signOut, in: app); signOut.tap()
        try await authorize(app)
        openSavedResult(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-target-'")).firstMatch.waitForExistence(timeout: 8))
        capture(app, "A3-relogin-original-history-without-replay")
    }
    func testExpiredSavedPhotoIsHiddenAndCannotBeResent() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"] != nil)
        let app = launch(); openSavedResult(app)
        let unavailable = app.staticTexts["cloud-result-media-expired"]
        reveal(unavailable, in: app)
        XCTAssertTrue(unavailable.exists)
        XCTAssertFalse(app.images["cloud-submitted-photo"].exists)
        XCTAssertFalse(app.buttons["cloud-result-resend"].isEnabled)
        let resultExpiry = app.descendants(matching: .any)["cloud-result-expiry"].firstMatch
        reveal(resultExpiry, in: app); XCTAssertTrue(resultExpiry.exists)
        capture(app, "A3-synthetic-expired-photo-hidden-no-resend")
    }

    func testComposerLayoutWithoutSubmitting() async throws {
        let app = launch()
        if !app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 4) { try await authorize(app) }
        prepareMarker(app, targets: ["a3_land", "a3_portrait"])
        capture(app, "A3-composer-localized-accessible-layout-no-submit")
        let picker = app.buttons["send-preview-display-picker"]
        reveal(picker, in: app)
        picker.tap(); app.buttons["send-preview-display-a3_portrait"].firstMatch.tap()
        capture(app, "A3-composer-portrait-layout-no-submit")
        app.buttons["root-send-close"].tap()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 5))
    }
    func testExistingResultLocalizedAccessibilityLayout() throws {
        let app = launch(); openSavedResult(app)
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'cloud-result-target-'")).firstMatch
        reveal(first, in: app)
        XCTAssertTrue(first.exists)
        capture(app, "A3-result-localized-accessible-statuses")
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.8))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.3)))
        capture(app, "A3-result-large-status-readable-after-scroll")
        let preview = app.buttons["cloud-result-preview-picker"]
        reveal(preview, in: app)
        capture(app, "A3-result-localized-accessible-frozen-preview")
    }
    func testReviewExistingResultsAndCompositionWithoutSending() throws {
        let app = launch(); openSavedResult(app)
        capture(app, "A3-review-original-results")
        let preview = app.buttons["cloud-result-preview-picker"]
        reveal(preview, in: app); preview.buttons.firstMatch.tap(); app.buttons["Landscape A"].tap()
        capture(app, "A3-review-frozen-landscape")
        preview.buttons.firstMatch.tap(); app.buttons["Portrait A"].tap()
        capture(app, "A3-review-frozen-portrait")
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["cloud-results-close"].tap()
        prepareMarker(app, targets: ["a3_land", "a3_portrait"])
        let picker = app.buttons["send-preview-display-picker"]
        reveal(picker, in: app); picker.tap(); app.buttons["send-preview-display-a3_portrait"].tap()
        let canvas = app.descendants(matching: .any)["selected-image-preview"].firstMatch
        canvas.pinch(withScale: 1.4, velocity: 1)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).press(forDuration: 0.1,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.45)))
        picker.tap(); app.buttons["send-preview-display-a3_land"].tap()
        picker.tap(); app.buttons["send-preview-display-a3_portrait"].tap()
        capture(app, "A3-review-per-aspect-composition")
        app.buttons["root-send-close"].tap()
        app.buttons["cloud-device-a3_land"].tap()
        XCTAssertTrue(app.images["cloud-preview-image"].waitForExistence(timeout: 10))
        capture(app, "A3-review-existing-frame-only")
    }

    private func fixtureControl(_ action: String) async throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_CONTROL_DIR"])
        let directory = URL(fileURLWithPath: path)
        try Data().write(to: directory.appending(path: "\(action).request"))
        let done = directory.appending(path: "\(action).done")
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: done.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: done.path))
    }
    func testReadRestrictionAndSameGrantRecovery() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_CONTROL_DIR"] != nil)
        let app = launch(); openSavedResult(app)
        XCTAssertTrue(app.images["cloud-submitted-photo"].waitForExistence(timeout: 5))
        try await fixtureControl("suspend")
        app.navigationBars.buttons.firstMatch.tap(); app.buttons["cloud-results-close"].tap()
        app.buttons["cloud-refresh-list"].firstMatch.tap()
        let problem = app.descendants(matching: .any)["cloud-read-problem"].firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["cloud-device-a3_land"].exists)
        let send = app.buttons["root-send-action"].firstMatch
        XCTAssertFalse(send.exists && send.isEnabled)
        capture(app, "A3-real-tenant-read-restriction-hides-private-state")
        try await fixtureControl("restore")
        app.buttons["cloud-refresh-list"].firstMatch.tap()
        XCTAssertTrue(app.buttons["cloud-device-a3_land"].waitForExistence(timeout: 15))
        let usable = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in send.exists && send.isEnabled }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [usable], timeout: 10), .completed)
        openSavedResult(app)
        XCTAssertTrue(app.images["cloud-submitted-photo"].waitForExistence(timeout: 5))
        capture(app, "A3-same-grant-read-recovery-history-without-resume")
    }

    func testUnknownRestorationTimingReadOnly() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TESSERAE_CLOUD_UI_RESULT_ID"] != nil)
        let app = launch()
        let started = try XCTUnwrap(launchStarted), returned = try XCTUnwrap(launchReturned)
        openSavedResult(app)
        assertOutcome("Outcome Unknown", device: "a3_land", in: app)
        let finished = ContinuousClock.now
        func seconds(_ from: ContinuousClock.Instant) -> Double {
            let duration = from.duration(to: finished).components
            return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
        }
        let record: [String: Any] = ["launchCallToVerifiedUnknownSeconds": seconds(started),
            "launchReturnToVerifiedUnknownSeconds": seconds(returned),
            "end": "Saved result target is hittable and its label contains Outcome Unknown",
            "includes": "XCUIApplication launch, Cloud list restore, automated opening history and saved result, AX polling",
            "excludes": "No photo/render POST; does not represent pure ledger decoding or automatic result presentation"]
        print("A3_UNKNOWN_TIMING " + String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!)
        capture(app, "A3-restarted-unknown-timing-read-only")
    }

}
