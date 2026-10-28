import Foundation
import Testing
@testable import TesseraeKit

struct DashboardNativeSettingsTests {
  private func fixture<T: Decodable>(_ name: String, as: T.Type) throws -> T {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Contracts/Fixtures/\(name)").standardizedFileURL
    return try TesseraeJSON.decoder().decode(T.self, from: Data(contentsOf: url))
  }

  @Test func conditionTextMatchesSharedWebBoundaryCases() throws {
    struct Case: Decodable {
      let actual: DashboardSettingValue
      let expected: DashboardSettingValue
      let matches: Bool
    }
    let cases = try fixture("dashboard-native-condition-cases.json", as: [Case].self)
    for example in cases {
      #expect(DashboardSettingsDraft.matches(example.actual, expected: example.expected) == example.matches)
    }
  }

  @Test func realServerNativeFixtureProducesTheSamePatchAndVisibility() throws {
    let settings = try fixture("dashboard-native-controls-response.json", as: DashboardSettings.self)
    let expected = try fixture("dashboard-native-controls-patch.json", as: DashboardSettingsPatch.self)
    let choices = try fixture("dashboard-native-location-choices.json", as: DashboardSettingChoices.self)
    var draft = DashboardSettingsDraft(settings)
    #expect(!draft.hasChanges)
    let conditional = try #require(settings.components.flatMap(\.fields).first { $0.name == "conditional" })
    #expect(conditional.isSupported && !draft.isVisible(conditional))
    for (name, value) in expected.inputs {
      let input = try #require(settings.inputs.first { $0.name == name })
      draft.setValue(value, for: input)
    }
    #expect(draft.isVisible(conditional))
    for (id, value) in expected.componentValues {
      let field = try #require(settings.components.flatMap(\.fields).first { $0.id == id })
      #expect(field.isSupported)
      draft.setValue(value, for: field, component: true)
    }
    #expect(draft.patch == expected)
    let place = try #require(DashboardSettingLocation(choices.choices.first?.value))
    #expect(place.timezone == "Asia/Shanghai")
  }

  @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_NATIVE_CONTROLS_HTTP_TEST"] == "1"))
  func nativeControlsRoundTripThroughPythonServer() async throws {
    struct Configuration: Decodable { let url: URL; let token: String; let dashboardID: String }
    let configPath = ProcessInfo.processInfo.environment["TESSERAE_NATIVE_CONTROLS_HTTP_CONFIG"]
      ?? "/tmp/tesserae-dashboard-native-integration.json"
    let config = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf:
      URL(fileURLWithPath: configPath)))
    try #require(config.url.host == "127.0.0.1")
    let instance = TesseraeInstance(id: "native-http-qa", name: "QA", baseURL: config.url,
      serverVersion: "dev", timezone: "UTC", webURL: config.url.absoluteString)
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: config.token, for: instance.id)
    let client = LiveTesseraeClient(credentials: credentials,
      identity: .init(appVersion: "integration", installationID: "native-controls-qa"))
    #expect(try await client.probe(baseURL: config.url).features.contains("dashboard_native_controls"))
    let saved = try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance)
    try #require(saved.settings["device_ids"] == .array([]))
    let fields = saved.components.flatMap(\.fields)
    let mode = try #require(saved.inputs.first { $0.name == "mode" })
    let conditional = try #require(fields.first { $0.name == "conditional" })
    let slider = try #require(fields.first { $0.type == "slider" })
    let location = try #require(fields.first { $0.type == "location_search" })
    let color = try #require(fields.first { $0.type == "color" })
    let choices = try await client.fetchDashboardSettingChoices(id: config.dashboardID,
      fieldID: location.id, query: "1,2", limit: 50, offset: 0,
      schemaRevision: saved.schemaRevision, instance: instance)
    let coordinateValue = try #require(choices.choices.first?.value)
    #expect(DashboardSettingLocation(coordinateValue)?.latitude == 1)
    var draft = DashboardSettingsDraft(saved)
    draft.setValue(.string("yes"), for: mode)
    draft.setValue(.string("Native"), for: conditional, component: true)
    draft.setValue(.number(1.15), for: slider, component: true)
    draft.setValue(coordinateValue, for: location, component: true)
    draft.setValue(.string("var(--accent)"), for: color, component: true)
    let updated = try await client.updateDashboardSettings(id: config.dashboardID, patch: draft.patch, instance: instance)
    let updatedFields = updated.components.flatMap(\.fields)
    #expect(updatedFields.first { $0.id == conditional.id }?.value == .string("Native"))
    #expect(updatedFields.first { $0.id == slider.id }?.value == .number(1.15))
    #expect(updatedFields.first { $0.id == location.id }?.value == coordinateValue)
    #expect(updatedFields.first { $0.id == color.id }?.value == .string("var(--accent)"))
    #expect(try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance) == updated)
    let invalid = DashboardSettingsPatch(revision: updated.revision,
      settings: ["name": .string("Must not save")], inputs: [mode.name: .string("no")],
      schemaRevision: updated.schemaRevision, componentValues: [conditional.id: .string("Hidden write")])
    await #expect(throws: DashboardSettingsValidationError.self) {
      try await client.updateDashboardSettings(id: config.dashboardID, patch: invalid, instance: instance)
    }
    #expect(try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance) == updated)
  }

  private func field(_ id: String, type: String = "string", value: DashboardSettingValue? = nil,
    conditions: [DashboardSettingVisibilityCondition] = [], editable: Bool = true
  ) -> DashboardSettingInput {
    .init(name: id, label: id, type: type, required: false, help: "", choices: [],
      secret: false, editable: editable, configured: value != nil, value: value,
      fieldID: id, resettable: true, visibilityConditions: conditions)
  }

  private func draft(_ fields: [DashboardSettingInput], inputs: [DashboardSettingInput] = []) -> DashboardSettingsDraft {
    .init(.init(kind: .canvas, dashboardID: "qa", revision: "1", canEdit: true,
      settings: [:], options: [:], inputs: inputs, webURL: "/pages/qa", schemaRevision: "s1",
      components: [.init(id: "component", label: "QA", kind: "canvas_element", widget: "qa", fields: fields)]))
  }

  @Test func conditionalDraftPreservesHiddenEditsAndOmittedResets() {
    let enabled = field("enabled", type: "boolean", value: .bool(true))
    let title = field("title", value: .string("Saved"),
      conditions: [.init(fieldID: "enabled", expected: .bool(true))])
    var draft = draft([enabled, title])
    draft.setValue(.string("Draft"), for: title, component: true)
    #expect(draft.patch.componentValues["title"] == .string("Draft"))
    draft.setValue(.bool(false), for: enabled, component: true)
    #expect(!draft.isVisible(title))
    #expect(draft.patch.componentValues == ["enabled": .bool(false)])
    #expect(draft.value(for: title, component: true) == .string("Draft"))
    draft.setValue(.bool(true), for: enabled, component: true)
    #expect(draft.patch.componentValues["title"] == .string("Draft"))
    draft.setValue(.bool(false), for: enabled, component: true)
    draft.reset(title, component: true)
    #expect(draft.patch.resetFields.isEmpty)
  }

  @Test func hiddenOnlyDraftProtectsExitAndSurvivesSavingOtherSettings() {
    let enabled = field("enabled", type: "boolean", value: .bool(false))
    let title = field("title", value: .string("Saved"),
      conditions: [.init(fieldID: enabled.id, expected: .bool(true))])
    var draft = draft([enabled, title])
    draft.setValue(.bool(true), for: enabled, component: true)
    draft.setValue(.string("Pending"), for: title, component: true)
    draft.restore(enabled, component: true)
    #expect(draft.hasChanges && !draft.hasSavableChanges)
    #expect(draft.patch.isEmpty)
    #expect(draft.hasChanges(for: title, component: true))
    var rebased = draft.rebased(afterSaving: draft.original)
    #expect(rebased.hasChanges && !rebased.hasSavableChanges)
    #expect(rebased.value(for: title, component: true) == .string("Pending"))
    rebased.setValue(.bool(true), for: enabled, component: true)
    #expect(rebased.patch.componentValues[title.id] == .string("Pending"))
  }

  @Test func conditionsResolveDeclaredControllersAndHiddenChains() {
    let mode = field("declared-mode", value: .string("custom"))
    let title = field("title", value: .string("Shown"),
      conditions: [.init(fieldID: mode.id, expected: .array([.string("custom"), .string("other")]))])
    let child = field("child", conditions: [.init(fieldID: title.id, expected: .object(["not": .string("")]))])
    var draft = draft([title, child], inputs: [mode])
    #expect(draft.isVisible(title) && draft.isVisible(child))
    draft.setValue(.string("default"), for: mode)
    #expect(!draft.isVisible(title) && !draft.isVisible(child))
    let cyclic = field("cycle", conditions: [.init(fieldID: "cycle", expected: .string("yes"))])
    #expect(!self.draft([cyclic]).isVisible(cyclic))
    let missing = field("missing", conditions: [.init(fieldID: "unknown", expected: .null)])
    #expect(!self.draft([missing]).isVisible(missing))
    let readonly = field("invalid", conditions: [.init(fieldID: "invalid", expected: .null)], editable: false)
    #expect(self.draft([readonly]).isVisible(readonly))
  }

  @Test(arguments: [
    (DashboardSettingValue.number(1), DashboardSettingValue.string("1"), true),
    (.bool(true), .string("true"), true), (.null, .string(""), true),
    (.array([.string("a"), .string("b")]), .array([.string("b"), .string("c")]), true),
    (.array([.string("a")]), .object(["not": .array([.string("b")])]), true),
    (.object(["latitude": .number(0)]), .null, false),
  ])
  func conditionMatching(actual: DashboardSettingValue, expected: DashboardSettingValue, matches: Bool) {
    #expect(DashboardSettingsDraft.matches(actual, expected: expected) == matches)
  }

  @Test func sliderKeepsStoredValuesAndUsesOffsetSteps() throws {
    let spec = DashboardSettingInput(name: "size", label: "Size", type: "slider", required: false,
      help: "", choices: [], secret: false, editable: true, configured: true, value: .number(1),
      min: 0.05, max: 2, step: 0.05, unit: "×")
    let slider = try #require(DashboardSettingSlider(spec))
    #expect(abs(slider.snapped(1.023) - 1) < 1e-9)
    #expect(slider.displayValue(.number(4)) == 2)
    #expect(spec.value == .number(1))
    #expect(spec.value(from: "1.5") == .number(1.5))
    #expect(spec.value(from: "") == .null)
    #expect(spec.isSupported)
    let uneven = DashboardSettingInput(name: "uneven", label: "Uneven", type: "slider", required: false,
      help: "", choices: [], secret: false, editable: true, configured: false, value: nil,
      min: 0, max: 1, step: 0.4)
    #expect(try #require(DashboardSettingSlider(uneven)).snapped(1) == 0.8)
  }

  @Test func coordinatesKeepZoneAndMetadataWithoutInventingOne() throws {
    let saved: DashboardSettingValue = .object(["name": .string("Saved place"),
      "country": .string("Country"), "admin1": .string("Region"),
      "latitude": .number(22), "longitude": .number(114), "timezone": .string("Asia/Hong_Kong")])
    let updated = try #require(DashboardSettingLocation.coordinates(latitude: 23, longitude: 115,
      name: "Saved place", timezone: "Asia/Hong_Kong", preserving: saved))
    let place = try #require(DashboardSettingLocation(updated))
    #expect(place.latitude == 23 && place.longitude == 115)
    #expect(place.timezone == "Asia/Hong_Kong")
    #expect(place.properties["country"] == .string("Country"))
    #expect(DashboardSettingLocation.coordinates(latitude: 91, longitude: 0, name: "", timezone: "", preserving: nil) == nil)
    #expect(DashboardSettingLocation.coordinates(latitude: 0, longitude: 0, name: "", timezone: "Made/Up", preserving: nil) == nil)
    let manual = try #require(DashboardSettingLocation.coordinates(latitude: 0, longitude: 0,
      name: "", timezone: "", preserving: nil))
    #expect(DashboardSettingLocation(manual)?.properties["timezone"] == nil)
  }

  @Test func colorPickerRoundTripsHexOpacityAndKeepsThemeText() throws {
    #expect(DashboardSettingColor(css: "#abc")?.css == "#AABBCC")
    #expect(DashboardSettingColor(css: "#1234")?.css == "#11223344")
    #expect(DashboardSettingColor(css: "red")?.css == "#FF0000")
    #expect(DashboardSettingColor(css: "transparent")?.css == "#00000000")
    #expect(DashboardSettingColor(css: "var(--ink)") == nil)
    let color = field("color", type: "color", value: .string("var(--ink)"))
    #expect(draft([color]).patch.isEmpty)
    #expect(color.value(from: "var(--ink)") == .string("var(--ink)"))
  }
}
