import XCTest

@MainActor
final class DashboardSettingsUITests: XCTestCase {
  override func setUpWithError() throws { continueAfterFailure = false }

  private func openDashboard(
    layout: String = "cards", chineseLargeText: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] = "1"
    app.launchEnvironment["TESSERAE_UI_TEST_DEMO_LATENCY_MS"] = "0"
    app.launchArguments += [
      "-dashboardLayoutMode", layout,
      "-AppleLanguages", chineseLargeText ? "(zh-Hans)" : "(en)",
      "-AppleLocale", chineseLargeText ? "zh_CN" : "en_US",
    ]
    if chineseLargeText {
      app.launchEnvironment["TESSERAE_UI_TEST_COLOR_SCHEME"] = "dark"
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
      ]
    }
    app.launch()
    let demo = app.buttons[chineseLargeText ? "使用演示数据体验" : "Explore with Demo Data"]
    XCTAssertTrue(demo.waitForExistence(timeout: 8))
    for _ in 0..<5 where !demo.isHittable { app.swipeUp() }
    demo.tap()
    app.buttons[chineseLargeText ? "仪表盘" : "Dashboards"].firstMatch.tap()
    let target = app.buttons[
      layout == "cards"
        ? "dashboard-settings-pantry-display-picpak-kitchen"
        : "dashboard-row-pantry-display-picpak-kitchen"]
    if !target.isHittable {
      let group = app.buttons["dashboard-section-toggle-display-picpak-kitchen"]
      if group.exists && group.value as? String == "Collapsed" { group.tap() }
    }
    XCTAssertTrue(target.waitForExistence(timeout: 5))
    if !target.isHittable { app.swipeUp() }
    target.tap()
    XCTAssertTrue(app.buttons["dashboard-settings-save"].waitForExistence(timeout: 5))
    return app
  }

  func testDetailSaveAndPush() {
    let app = openDashboard()
    let preview = app.descendants(matching: .any)["dashboard-settings-preview"].firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertGreaterThan(preview.frame.height, 200)
    XCTAssertFalse(app.staticTexts["Preview and Push"].exists)
    XCTAssertFalse(app.buttons["dashboard-settings-save"].isEnabled)
    let overviewShot = XCTAttachment(screenshot: app.screenshot())
    overviewShot.name = "Dashboard native settings"
    overviewShot.lifetime = .keepAlways
    add(overviewShot)
    let icon = app.buttons["dashboard-settings-icon"]
    scrollTo(icon, in: app)
    icon.tap()
    let calendar = app.buttons["dashboard-icon-calendar"]
    XCTAssertTrue(calendar.waitForExistence(timeout: 3))
    let iconShot = XCTAttachment(screenshot: app.screenshot())
    iconShot.name = "Dashboard actual icon picker"
    iconShot.lifetime = .keepAlways
    add(iconShot)
    calendar.tap()
    XCTAssertEqual(icon.value as? String, "Calendar")
    let name = app.textFields["dashboard-settings-name"]
    scrollTo(name, in: app)
    name.tap()
    name.typeText(" Updated")
    scrollToTop(in: app)
    XCTAssertTrue(app.buttons["dashboard-settings-save"].isEnabled)
    XCTAssertFalse(app.buttons["dashboard-settings-push"].isEnabled)
    app.buttons["dashboard-settings-save"].tap()
    scrollToTop(in: app)
    XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 4))
    XCTAssertFalse(app.buttons["dashboard-settings-save"].isEnabled)
    app.swipeDown()
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Dashboard native settings saved"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    app.buttons["dashboard-settings-push"].tap()
    XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
    app.buttons["Cancel"].tap()
  }

  func testListEntryAndUnsavedBackProtection() {
    let app = openDashboard(layout: "list")
    let name = app.textFields["dashboard-settings-name"]
    scrollTo(name, in: app)
    name.tap()
    name.typeText(" Draft")
    app.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.alerts["Discard Changes?"].waitForExistence(timeout: 3))
    app.alerts.buttons["Keep Editing"].tap()
    XCTAssertTrue(app.textFields["dashboard-settings-name"].exists)
    XCTAssertTrue(app.buttons["dashboard-settings-save"].isEnabled)
    app.buttons["Back"].firstMatch.tap()
    app.alerts.buttons["Discard Changes"].tap()
    XCTAssertTrue(app.descendants(matching: .any)["dashboard-list"].waitForExistence(timeout: 3))
  }

  func testCompactSettingsHierarchyAndFieldDetails() {
    let app = openDashboard()
    let updates = app.buttons["dashboard-settings-updates"]
    scrollTo(updates, in: app)
    XCTAssertFalse(app.textFields["dashboard-settings-refresh-minutes"].exists)
    updates.tap()
    let interval = app.textFields["dashboard-settings-refresh-minutes"]
    XCTAssertTrue(interval.waitForExistence(timeout: 3))
    replaceText(interval, with: "15")
    navigateBack(in: app)
    XCTAssertTrue(app.buttons["dashboard-settings-save"].isEnabled)
    scrollTo(updates, in: app)
    updates.tap()
    XCTAssertEqual(interval.value as? String, "15")
    navigateBack(in: app)

    let reminders = app.buttons["dashboard-component-demo-reminders"]
    scrollTo(reminders, in: app)
    reminders.tap()
    XCTAssertFalse(app.staticTexts["Use widget default"].exists)
    XCTAssertFalse(app.textFields["Title"].exists)
    XCTAssertTrue(app.staticTexts["Selections"].exists)
    XCTAssertTrue(app.staticTexts["Text"].exists)
    XCTAssertTrue(app.staticTexts["Numbers"].exists)
    let title = app.buttons["dashboard-field-detail-demo-reminders-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 3))
    search.tap()
    search.typeText("Title")
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    XCTAssertFalse(app.buttons["dashboard-field-choices-demo-reminders-list"].exists)
    title.tap()
    XCTAssertTrue(app.navigationBars["Title"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["About this setting"].waitForExistence(timeout: 3))
    XCTAssertTrue(app.buttons["Use widget default"].exists)
    replaceText(app.textFields["Title"], with: "Edited title")
    navigateBack(in: app)
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    XCTAssertTrue(app.staticTexts["Edited title"].exists)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Compact component settings"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testComponentChoicesAndPrioritySurviveNavigationAndSave() {
    let app = openDashboard()
    let reminders = app.buttons["dashboard-component-demo-reminders"]
    scrollTo(reminders, in: app)
    reminders.tap()
    app.buttons["dashboard-field-choices-demo-reminders-list"].tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 4))
    search.tap()
    search.typeText("Work")
    let work = app.buttons["dashboard-choice-work"]
    XCTAssertTrue(work.waitForExistence(timeout: 4))
    work.tap()
    finishSelection(in: app)
    let titleRow = app.buttons["dashboard-field-detail-demo-reminders-title"]
    scrollTo(titleRow, in: app)
    titleRow.tap()
    let title = app.textFields["Title"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    replaceText(title, with: "Groceries for tonight")
    navigateBack(in: app)
    navigateBack(in: app)
    XCTAssertTrue(app.buttons["dashboard-settings-save"].isEnabled)

    let album = app.buttons["dashboard-component-demo-album"]
    scrollTo(album, in: app)
    album.tap()
    let showLabel = app.switches["Show label"]
    scrollTo(showLabel, in: app)
    XCTAssertEqual(showLabel.value as? String, "1")
    showLabel.tap()
    XCTAssertEqual(showLabel.value as? String, "0")
    app.buttons["dashboard-field-detail-demo-album-show"].tap()
    XCTAssertTrue(app.staticTexts["About this setting"].waitForExistence(timeout: 3))
    navigateBack(in: app)
    app.buttons["dashboard-field-choices-demo-album-players"].tap()
    let up = app.buttons["dashboard-choice-up-media_player.kitchen"]
    XCTAssertTrue(up.waitForExistence(timeout: 4))
    XCTAssertTrue(up.isEnabled)
    up.tap()
    XCTAssertFalse(up.isEnabled)
    finishSelection(in: app)
    navigateBack(in: app)
    app.buttons["dashboard-settings-save"].tap()
    scrollToTop(in: app)
    XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 5))

    scrollTo(reminders, in: app)
    reminders.tap()
    XCTAssertTrue(app.staticTexts["Groceries for tonight"].waitForExistence(timeout: 3))
    titleRow.tap()
    XCTAssertEqual(title.value as? String, "Groceries for tonight")
    navigateBack(in: app)
    app.buttons["dashboard-field-choices-demo-reminders-list"].tap()
    XCTAssertTrue(app.staticTexts["Work"].firstMatch.waitForExistence(timeout: 4))
    finishSelection(in: app)
    navigateBack(in: app)
    scrollTo(album, in: app)
    album.tap()
    app.buttons["dashboard-field-choices-demo-album-players"].tap()
    XCTAssertTrue(up.waitForExistence(timeout: 4))
    XCTAssertFalse(up.isEnabled)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Component media priority saved"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testComponentChoicesChineseLargeTextDarkLayout() {
    let app = openDashboard(layout: "list", chineseLargeText: true)
    let overviewShot = XCTAttachment(screenshot: app.screenshot())
    overviewShot.name = "Dashboard settings Chinese AX5 dark"
    overviewShot.lifetime = .keepAlways
    add(overviewShot)
    let album = app.buttons["dashboard-component-demo-album"]
    scrollTo(album, in: app)
    album.tap()
    let players = app.buttons["dashboard-field-choices-demo-album-players"]
    XCTAssertTrue(players.waitForExistence(timeout: 5))
    let componentShot = XCTAttachment(screenshot: app.screenshot())
    componentShot.name = "Compact Chinese AX5 component settings"
    componentShot.lifetime = .keepAlways
    add(componentShot)
    players.tap()
    let move = app.buttons["dashboard-choice-up-media_player.kitchen"]
    scrollTo(move, in: app)
    XCTAssertTrue(move.isHittable && move.isEnabled)
    move.tap()
    XCTAssertFalse(move.isEnabled)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Chinese AX5 dark component choices"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  /// Uses only unbound, disposable copies and the phone's existing pairing.
  func testLiveComponentChoicesAndPrioritySaveAndReload() throws {
    let manifest = ProcessInfo.processInfo.environment["TESSERAE_COMPONENT_QA_JSON"] ?? ""
    try XCTSkipIf(manifest.isEmpty, "Requires prepared unbound component QA copies")
    let fixture = try JSONDecoder().decode(ComponentDeviceQA.self, from: Data(manifest.utf8))
    let app = XCUIApplication()
    app.launchArguments += [
      "-dashboardLayoutMode", "list", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    openLiveComponentField(app, field: fixture.reminders)
    let choice = app.buttons["dashboard-choice-\(fixture.reminders.choiceValue ?? "")"]
    scrollTo(choice, in: app)
    choice.tap()
    returnToLiveSettings(app, field: fixture.reminders)
    saveLiveSettings(app)
    app.terminate()
    app.launch()
    openLiveComponentField(app, field: fixture.reminders)
    XCTAssertTrue(
      app.staticTexts[fixture.reminders.choiceLabel ?? ""].firstMatch.waitForExistence(timeout: 8))

    app.terminate()
    app.launch()
    openLiveComponentField(app, field: fixture.media)
    let moveValue = fixture.media.moveUpValue ?? ""
    let up = app.buttons["dashboard-choice-up-\(moveValue)"]
    scrollTo(up, in: app)
    XCTAssertTrue(up.isEnabled)
    up.tap()
    XCTAssertFalse(up.isEnabled)
    returnToLiveSettings(app, field: fixture.media)
    saveLiveSettings(app)
    app.terminate()
    app.launch()
    openLiveComponentField(app, field: fixture.media)
    XCTAssertTrue(up.waitForExistence(timeout: 8))
    XCTAssertFalse(up.isEnabled)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Live NAS component media priority reloaded on iPhone"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private struct ComponentDeviceQA: Decodable {
    let reminders: LiveComponentField
    let media: LiveComponentField
  }

  private struct LiveComponentField: Decodable {
    let pageID: String
    let pageName: String
    let componentID: String?
    let fieldID: String
    let choiceValue: String?
    let choiceLabel: String?
    let moveUpValue: String?
    enum CodingKeys: String, CodingKey {
      case pageID = "page_id"
      case pageName = "page_name"
      case componentID = "component_id"
      case fieldID = "field_id"
      case choiceValue = "choice_value"
      case choiceLabel = "choice_label"
      case moveUpValue = "move_up_value"
    }
  }

  private func openLiveComponentField(_ app: XCUIApplication, field: LiveComponentField) {
    let tab = app.buttons["Dashboards"].firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 20), "The phone must already be paired")
    tab.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    replaceText(search, with: field.pageName)
    let row = app.buttons["dashboard-row-\(field.pageID)-unassigned"]
    XCTAssertTrue(row.waitForExistence(timeout: 20))
    row.tap()
    XCTAssertTrue(app.buttons["dashboard-settings-save"].waitForExistence(timeout: 12))
    if let id = field.componentID {
      let component = app.buttons["dashboard-component-\(id)"]
      scrollTo(component, in: app)
      component.tap()
    }
    let choices = app.buttons["dashboard-field-choices-\(field.fieldID)"]
    scrollTo(choices, in: app)
    choices.tap()
  }

  private func returnToLiveSettings(_ app: XCUIApplication, field: LiveComponentField) {
    finishSelection(in: app)
    if field.componentID != nil { navigateBack(in: app) }
  }

  private func saveLiveSettings(_ app: XCUIApplication) {
    let save = app.buttons["dashboard-settings-save"]
    XCTAssertTrue(save.isEnabled)
    save.tap()
    scrollToTop(in: app)
    XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 15))
    XCTAssertFalse(save.isEnabled)
  }

  /// Opt-in acceptance test against the phone's existing pairing. The server-side
  /// fixture must be created without display bindings and removed after the run.
  func testLiveServerSettingsSaveAndReload() throws {
    let fixtureID = ProcessInfo.processInfo.environment["TESSERAE_LIVE_DASHBOARD_ID"] ?? ""
    try XCTSkipIf(fixtureID.isEmpty, "Requires an explicitly prepared live-server QA fixture")

    let app = XCUIApplication()
    app.launchArguments += [
      "-dashboardLayoutMode", "list", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
    ]
    app.launch()
    openLiveFixture(app, id: fixtureID)
    let name = app.textFields["dashboard-settings-name"]
    XCTAssertEqual(name.value as? String, "Dashboard Settings Device QA")
    XCTAssertTrue(name.isEnabled, "Grant Dashboard editing to this phone before running")
    replaceText(name, with: "Dashboard Settings Device QA Updated")

    openSettingDetail("QA Message", in: app)
    let message = app.textFields["QA Message"]
    replaceText(message, with: "Saved from iPhone")
    navigateBack(in: app)
    openSettingDetail("QA Number", in: app)
    let number = app.textFields["QA Number"]
    replaceText(number, with: "23")
    navigateBack(in: app)
    let enabled = app.switches["QA Enabled"]
    scrollTo(enabled, in: app)
    XCTAssertEqual(enabled.value as? String, "0")
    enabled.tap()

    let save = app.buttons["dashboard-settings-save"]
    save.tap()
    XCTAssertTrue(
      app.navigationBars["Dashboard Settings Device QA Updated"].waitForExistence(timeout: 15))
    // Wait for server acknowledgement, then restart to prove persistence rather
    // than merely reading the accepted draft still held by the current screen.
    app.terminate()
    app.launch()
    openLiveFixture(app, id: fixtureID)
    XCTAssertEqual(name.value as? String, "Dashboard Settings Device QA Updated")
    openSettingDetail("QA Message", in: app)
    XCTAssertEqual(message.value as? String, "Saved from iPhone")
    navigateBack(in: app)
    openSettingDetail("QA Number", in: app)
    XCTAssertEqual(number.value as? String, "23")
    navigateBack(in: app)
    scrollTo(enabled, in: app)
    XCTAssertEqual(enabled.value as? String, "1")
    let screenshot = XCTAttachment(screenshot: app.screenshot())
    screenshot.name = "Live NAS Dashboard settings reloaded on device"
    screenshot.lifetime = .keepAlways
    add(screenshot)
  }

  private func openLiveFixture(_ app: XCUIApplication, id: String) {
    let tab = app.buttons["Dashboards"].firstMatch
    XCTAssertTrue(tab.waitForExistence(timeout: 20), "The phone must already be paired")
    tab.tap()
    let search = app.searchFields.firstMatch
    XCTAssertTrue(search.waitForExistence(timeout: 8))
    search.tap()
    search.typeText("Dashboard Settings Device QA")
    let row = app.buttons["dashboard-row-\(id)-unassigned"]
    XCTAssertTrue(row.waitForExistence(timeout: 20), "Expected the unbound QA Dashboard")
    row.tap()
    XCTAssertTrue(app.textFields["dashboard-settings-name"].waitForExistence(timeout: 12))
  }

  private func openSettingDetail(_ label: String, in app: XCUIApplication) {
    let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    scrollTo(row, in: app)
    row.tap()
    XCTAssertTrue(app.navigationBars[label].waitForExistence(timeout: 4))
  }

  private func navigateBack(in app: XCUIApplication) {
    // Search focus presents its own Close action before the navigation back button.
    let closeSearch = app.navigationBars.buttons["Close"]
    if closeSearch.exists { closeSearch.tap() }
    let back = app.navigationBars.buttons["BackButton"].firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 4))
    back.tap()
  }

  private func finishSelection(in app: XCUIApplication) {
    let done = app.buttons["dashboard-choices-done"]
    for _ in 0..<5 {
      if done.exists && done.isHittable { break }
      app.swipeDown()
    }
    XCTAssertTrue(done.waitForExistence(timeout: 4))
    done.tap()
  }

  private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      if element.exists && element.isHittable { return }
      if element.exists && element.frame.midY < app.windows.firstMatch.frame.midY {
        app.swipeDown(velocity: .slow)
      } else {
        app.swipeUp(velocity: .slow)
      }
    }
    if !element.exists || !element.isHittable {
      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Unreachable component control"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTAssertTrue(element.exists && element.isHittable, app.debugDescription)
  }

  private func scrollToTop(in app: XCUIApplication) {
    let preview = app.buttons["dashboard-settings-push"]
    for _ in 0..<6 {
      if preview.exists && preview.isHittable { return }
      app.swipeDown()
    }
  }

  private func replaceText(_ field: XCUIElement, with value: String) {
    // Inline fields align values to the right; start deletion at the trailing edge.
    field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
    let previous = field.value as? String ?? ""
    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count))
    field.typeText(value)
  }
}
