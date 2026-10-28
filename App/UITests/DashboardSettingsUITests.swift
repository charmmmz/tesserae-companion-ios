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

  func testHiddenDraftSurvivesSaveAndProtectsExit() {
    let app = openDashboard()
    let weather = app.buttons["dashboard-component-demo-weather"]
    scrollTo(weather, in: app)
    weather.tap()
    let title = app.buttons["dashboard-field-detail-demo-weather-title"]
    scrollTo(title, in: app)
    title.tap()
    replaceText(app.textFields["Forecast title"], with: "Hidden draft")
    navigateBack(in: app)
    let details = app.switches["Detailed forecast"]
    scrollTo(details, in: app)
    details.tap()
    XCTAssertFalse(title.exists)
    navigateBack(in: app)
    scrollToTop(in: app)
    let save = app.buttons["dashboard-settings-save"]
    XCTAssertTrue(save.isEnabled)
    save.tap()
    XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 5))
    XCTAssertFalse(save.isEnabled)
    app.buttons["Back"].firstMatch.tap()
    XCTAssertTrue(app.alerts["Discard Changes?"].waitForExistence(timeout: 3))
    app.alerts.buttons["Keep Editing"].tap()
    scrollTo(weather, in: app)
    weather.tap()
    scrollTo(details, in: app)
    details.tap()
    scrollTo(title, in: app)
    title.tap()
    XCTAssertEqual(app.textFields["Forecast title"].value as? String, "Hidden draft")
  }

  func testNativeColorPickerTargetAndPresentation() {
    let app = openDashboard()
    let weather = app.buttons["dashboard-component-demo-weather"]
    scrollTo(weather, in: app)
    weather.tap()
    let color = app.buttons["dashboard-field-detail-demo-weather-color"]
    scrollTo(color, in: app)
    color.tap()
    let picker = app.buttons["dashboard-color-demo-weather-color"]
    XCTAssertTrue(picker.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(picker.frame.height, 44 - 0.5)
    picker.tap()
    XCTAssertTrue(app.otherElements["UIColorPickerView"].waitForExistence(timeout: 5))
    let shot = XCTAttachment(screenshot: app.screenshot())
    shot.name = "Native Dashboard system color picker"
    shot.lifetime = .keepAlways
    add(shot)
    dismissColorPicker(in: app)
    XCTAssertEqual(app.textFields["dashboard-color-value-demo-weather-color"].value as? String, "var(--ink)")
  }

  func testNativeControlsPreserveConditionsLocationAndColor() {
    let app = openDashboard()
    let weather = app.buttons["dashboard-component-demo-weather"]
    scrollTo(weather, in: app)
    weather.tap()
    let title = app.buttons["dashboard-field-detail-demo-weather-title"]
    XCTAssertTrue(title.waitForExistence(timeout: 3))
    let details = app.switches["Detailed forecast"]
    scrollTo(details, in: app)
    details.tap()
    XCTAssertFalse(title.exists)
    details.tap()
    scrollTo(title, in: app)
    title.tap()
    replaceText(app.textFields["Forecast title"], with: "Preserved forecast")
    navigateBack(in: app)

    let size = app.buttons["dashboard-field-detail-demo-weather-size"]
    scrollTo(size, in: app)
    size.tap()
    let slider = app.sliders["dashboard-slider-demo-weather-size"]
    XCTAssertTrue(slider.waitForExistence(timeout: 3))
    slider.adjust(toNormalizedSliderPosition: 0.6)
    let number = app.textFields["dashboard-number-demo-weather-size"]
    replaceText(number, with: "1.25")
    let reset = app.buttons["Use widget default"]
    scrollTo(reset, in: app)
    reset.tap()
    scrollTo(number, in: app)
    XCTAssertEqual(number.value as? String, "1")
    replaceText(number, with: "1.25")
    let sliderShot = XCTAttachment(screenshot: app.screenshot())
    sliderShot.name = "Native Dashboard slider exact value"
    sliderShot.lifetime = .keepAlways
    add(sliderShot)
    navigateBack(in: app)

    let color = app.buttons["dashboard-field-detail-demo-weather-color"]
    scrollTo(color, in: app)
    color.tap()
    let picker = app.buttons["dashboard-color-demo-weather-color"]
    XCTAssertTrue(picker.waitForExistence(timeout: 3))
    XCTAssertGreaterThanOrEqual(picker.frame.height, 44 - 0.5)
    picker.tap()
    XCTAssertTrue(app.otherElements["UIColorPickerView"].waitForExistence(timeout: 5))
    dismissColorPicker(in: app)
    let colorValue = app.textFields["dashboard-color-value-demo-weather-color"]
    XCTAssertEqual(colorValue.value as? String, "var(--ink)")
    replaceText(colorValue, with: "#336699")
    let colorShot = XCTAttachment(screenshot: app.screenshot())
    colorShot.name = "Native Dashboard color picker and theme text"
    colorShot.lifetime = .keepAlways
    add(colorShot)
    navigateBack(in: app)

    let location = app.buttons["dashboard-field-detail-demo-weather-location"]
    scrollTo(location, in: app)
    location.tap()
    let query = app.textFields["dashboard-location-query"]
    XCTAssertTrue(query.waitForExistence(timeout: 3))
    query.tap()
    query.typeText("Athens")
    let athens = app.buttons["Athens, Attica, Greece"]
    XCTAssertTrue(athens.waitForExistence(timeout: 5))
    athens.tap()
    let coordinates = app.buttons["dashboard-location-coordinates"]
    scrollTo(coordinates, in: app)
    coordinates.tap()
    XCTAssertEqual(app.textFields["dashboard-location-timezone"].value as? String, "Europe/Athens")
    replaceText(app.textFields["dashboard-location-latitude"], with: "38")
    let coordinateShot = XCTAttachment(screenshot: app.screenshot())
    coordinateShot.name = "Native Dashboard coordinates and preserved timezone"
    coordinateShot.lifetime = .keepAlways
    add(coordinateShot)
    app.buttons["dashboard-location-done"].tap()
    navigateBack(in: app)
    navigateBack(in: app)
    scrollToTop(in: app)
    app.buttons["dashboard-settings-save"].tap()
    XCTAssertTrue(app.staticTexts["Settings saved"].waitForExistence(timeout: 5))

    scrollTo(weather, in: app)
    weather.tap()
    scrollTo(size, in: app)
    size.tap()
    XCTAssertEqual(app.textFields["dashboard-number-demo-weather-size"].value as? String, "1.25")
    navigateBack(in: app)
    scrollTo(color, in: app)
    color.tap()
    XCTAssertEqual(colorValue.value as? String, "#336699")
    navigateBack(in: app)
    scrollTo(location, in: app)
    location.tap()
    scrollTo(coordinates, in: app)
    coordinates.tap()
    XCTAssertEqual(app.textFields["dashboard-location-latitude"].value as? String, "38.0")
    XCTAssertEqual(app.textFields["dashboard-location-timezone"].value as? String, "Europe/Athens")
  }

  func testNativeControlsAtAccessibilitySize() {
    let app = openDashboard(chineseLargeText: true)
    let weather = app.buttons["dashboard-component-demo-weather"]
    scrollTo(weather, in: app)
    weather.tap()
    for id in ["demo-weather-size", "demo-weather-color", "demo-weather-location"] {
      let field = app.buttons["dashboard-field-detail-\(id)"]
      scrollFullyTo(field, in: app)
      field.tap()
      let title = id == "demo-weather-size" ? "Text size" : id == "demo-weather-color" ? "Accent color" : "Location"
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
      let shot = XCTAttachment(screenshot: app.screenshot())
      shot.name = "Native Dashboard AX5 \(id)"
      shot.lifetime = .keepAlways
      add(shot)
      if id == "demo-weather-location" {
        let coordinates = app.buttons["dashboard-location-coordinates"]
        scrollTo(coordinates, in: app)
        coordinates.tap()
        XCTAssertTrue(app.staticTexts["纬度"].exists)
        XCTAssertTrue(app.staticTexts["经度"].exists)
        let coordinateShot = XCTAttachment(screenshot: app.screenshot())
        coordinateShot.name = "Native Dashboard AX5 coordinate labels"
        coordinateShot.lifetime = .keepAlways
        add(coordinateShot)
        app.buttons["dashboard-location-done"].tap()
      }
      navigateBack(in: app)
    }
  }

  func testDetailSaveAndPush() {
    let app = openDashboard()
    let preview = app.descendants(matching: .any)["dashboard-settings-preview"].firstMatch
    XCTAssertTrue(preview.waitForExistence(timeout: 3))
    XCTAssertGreaterThan(preview.frame.height, 200)
    let previewPush = app.buttons["dashboard-settings-push"]
    XCTAssertEqual(previewPush.frame.width, 44, accuracy: 0.5)
    XCTAssertEqual(previewPush.frame.height, 44, accuracy: 0.5)
    XCTAssertFalse(app.staticTexts["Preview and Push"].exists)
    XCTAssertFalse(app.buttons["dashboard-settings-save"].isEnabled)
    let more = app.buttons["dashboard-settings-more"]
    let saveButton = app.buttons["dashboard-settings-save"]
    XCTAssertTrue(more.waitForExistence(timeout: 3))
    for button in [more, saveButton] {
      XCTAssertGreaterThanOrEqual(button.frame.width, 44 - 0.01)
      XCTAssertGreaterThanOrEqual(button.frame.height, 44 - 0.01)
    }
    XCTAssertEqual(more.frame.width, saveButton.frame.width, accuracy: 0.5)
    XCTAssertEqual(more.frame.midY, saveButton.frame.midY, accuracy: 0.5)
    XCTAssertLessThanOrEqual(more.frame.maxX, saveButton.frame.minX + 0.5)
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
    let toolbarShot = XCTAttachment(screenshot: app.screenshot())
    toolbarShot.name = "Dashboard settings unsaved toolbar"
    toolbarShot.lifetime = .keepAlways
    add(toolbarShot)
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
    for (identifier, title) in [
      ("dashboard-settings-displays", "Displays"),
      ("dashboard-settings-appearance", "Appearance"),
    ] {
      let preference = app.buttons[identifier]
      scrollTo(preference, in: app)
      preference.tap()
      XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 3))
      let screenshot = XCTAttachment(screenshot: app.screenshot())
      screenshot.name = "Dashboard \(title) paper background"
      screenshot.lifetime = .keepAlways
      add(screenshot)
      navigateBack(in: app)
    }
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
    let componentShot = XCTAttachment(screenshot: app.screenshot())
    componentShot.name = "Dashboard component paper background"
    componentShot.lifetime = .keepAlways
    add(componentShot)
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
    let fieldShot = XCTAttachment(screenshot: app.screenshot())
    fieldShot.name = "Dashboard field paper background"
    fieldShot.lifetime = .keepAlways
    add(fieldShot)
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
    XCTAssertTrue(app.buttons["dashboard-choices-done"].isHittable)
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
    let previewPush = app.buttons["dashboard-settings-push"]
    XCTAssertEqual(previewPush.frame.width, 44, accuracy: 0.5)
    XCTAssertEqual(previewPush.frame.height, 44, accuracy: 0.5)
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
    let refresh = app.buttons["dashboard-choices-refresh"]
    let done = app.buttons["dashboard-choices-done"]
    for action in [refresh, done] {
      XCTAssertTrue(action.isHittable)
      XCTAssertGreaterThanOrEqual(action.frame.width, 44 - 0.01)
      XCTAssertGreaterThanOrEqual(action.frame.height, 44 - 0.01)
    }
    XCTAssertEqual(refresh.frame.midY, done.frame.midY, accuracy: 0.5)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Chinese AX5 dark component choices"
    attachment.lifetime = .keepAlways
    add(attachment)
    done.tap()
    XCTAssertTrue(app.buttons["dashboard-field-choices-demo-album-players"].waitForExistence(timeout: 3))
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

  private func dismissColorPicker(in app: XCUIApplication) {
    let popup = app.otherElements["UIColorPickerView"]
    let close = app.buttons.matching(NSPredicate(format: "label ==[c] %@", "close")).firstMatch
    if close.exists && close.isHittable {
      close.tap()
    } else {
      // iPad uses a popover with an outside dismissal region and no Close button.
      app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.15)).tap()
    }
    XCTAssertTrue(popup.waitForNonExistence(timeout: 5))
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

  private func scrollFullyTo(_ element: XCUIElement, in app: XCUIApplication) {
    for _ in 0..<10 {
      let top = max(app.navigationBars.firstMatch.frame.maxY,
        app.searchFields.firstMatch.exists ? app.searchFields.firstMatch.frame.maxY : 0) + 8
      let window = app.windows.firstMatch.frame
      let tabs = app.tabBars.firstMatch
      let bottom = tabs.exists && tabs.frame.minY > window.midY ? tabs.frame.minY - 8 : window.maxY - 20
      if element.exists && element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
      let distance = element.exists ? min(160, max(-160, (top + bottom) / 2 - element.frame.midY)) : -160
      let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
      let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55 + distance / window.height))
      start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }
    XCTFail("Expected a fully visible setting row: \(element)")
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
