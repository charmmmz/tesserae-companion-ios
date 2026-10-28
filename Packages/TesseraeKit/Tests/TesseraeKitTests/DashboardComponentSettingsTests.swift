import Foundation
import Testing

@testable import TesseraeKit

struct DashboardComponentSettingsTests {
  private var instance: TesseraeInstance {
    .init(id: "component-test", name: "Test", baseURL: URL(string: "https://tesserae.example")!,
          serverVersion: "dev", timezone: "UTC", webURL: "/")
  }

  private func fixture() throws -> DashboardSettings {
    try TesseraeJSON.decoder().decode(DashboardSettings.self, from: Data(#"""
    {
      "dashboard_id":"component-qa","kind":"canvas","revision":"page-1",
      "schema_revision":"schema-1","can_edit":true,
      "settings":{"name":"Components","device_ids":[]},"options":{},"web_url":"/pages/component-qa",
      "inputs":[{
        "name":"shared","field_id":"input-shared","label":"Shared label","type":"string",
        "required":false,"help":"","choices":[],"secret":false,"editable":true,"configured":true,
        "value_state":"mixed","has_override":true,"can_clear":true,"can_reset":true,"default":"Default"
      }],
      "components":[{
        "id":"component-one","label":"First album","widget_id":"album_art","kind":"canvas_element",
        "available":true,"fragment":"cover","source_name":null,
        "fields":[
          {"name":"entities","field_id":"field-players","label":"Players","type":"multiselect",
           "editable":true,"configured":true,"value":["offline","kitchen"],"dynamic_choices":true,
           "has_override":true,"value_state":"uniform","can_clear":true,"can_reset":true,"default":[]},
          {"name":"count","field_id":"field-count","label":"Count","type":"number","editable":true,
           "configured":false,"value":8,"default":8,"value_state":"uniform","has_override":false,
           "can_clear":true,"can_reset":true,"minimum":1,"maximum":30,"step":1},
          {"name":"token","field_id":"field-secret","label":"Token","type":"password","editable":true,
           "configured":true,"secret":true,"value":"must-not-appear","default":"must-not-appear",
           "choices":[{"value":"must-not-appear","label":"Private"}],"has_override":true,"value_state":"uniform",
           "can_clear":true,"can_reset":true},
          {"name":"future","field_id":"field-future","label":"Future","type":"location_search",
           "editable":false,"configured":true,"value":{"lat":22,"lon":114},"readonly_reason":"unsupported_type"}
        ]
      }],
      "coverage":{"status":"partial","editable_fields":4,"readonly_fields":1,"unavailable_components":0}
    }
    """#.utf8))
  }

  private func serverFixture(_ name: String) throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Contracts/Fixtures/\(name)").standardizedFileURL
    return try Data(contentsOf: url)
  }

  @Test func realServerFixtureKeepsInstancesDefaultsAndUnavailableControlsSeparate() throws {
    let detail = try TesseraeJSON.decoder().decode(DashboardSettings.self,
      from: serverFixture("dashboard-component-settings-response.json"))
    #expect(detail.components.map(\.kind) == ["canvas_element", "code_source", "code_source", "binding"])
    #expect(Set(detail.components.map(\.id)).count == 4)
    let fields = detail.components.flatMap(\.fields)
    #expect(Set(fields.map(\.id)).count == fields.count)
    let coverage = try #require(detail.coverage)
    #expect(coverage.editableFields == fields.filter(\.editable).count)
    #expect(coverage.readonlyFields == fields.filter { !$0.editable }.count)
    #expect(coverage.status == "partial")
    let count = try #require(detail.components.first?.fields.first { $0.name == "count" })
    #expect(count.value == .number(3))
    #expect(count.defaultValue == .number(3))
    #expect(count.usingDefault)
    #expect(count.min == 0 && count.max == 20 && count.step == 1)
    let players = try #require(detail.components.first?.fields.first { $0.name == "players" })
    #expect(players.value == .array([.string("stale"), .string("a")]))
    #expect(players.choicesDynamic && players.choices.isEmpty)
    for secret in fields.filter(\.secret) {
      #expect(secret.value == nil && secret.defaultValue == nil && secret.choices.isEmpty)
    }
    for readonly in fields.filter({ !$0.editable }) {
      #expect(!readonly.isSupported && !readonly.canClear && !readonly.resettable)
    }
    #expect(!DashboardSettingsDraft(detail).hasChanges)
  }

  @Test func realServerPatchTargetsOneInstanceAndDoesNotPersistDisplayedDefaults() throws {
    let detail = try TesseraeJSON.decoder().decode(DashboardSettings.self,
      from: serverFixture("dashboard-component-settings-response.json"))
    let expected = try TesseraeJSON.decoder().decode(DashboardSettingsPatch.self,
      from: serverFixture("dashboard-component-settings-patch.json"))
    let changedID = try #require(expected.componentValues.keys.first)
    let target = try #require(detail.components.flatMap(\.fields).first { $0.id == changedID })
    var draft = DashboardSettingsDraft(detail)
    draft.setValue(expected.componentValues[changedID], for: target, component: true)
    #expect(draft.patch == expected)
    #expect(draft.patch.settings.isEmpty && draft.patch.inputs.isEmpty)
    #expect(draft.patch.componentValues.count == 1)
    let encoded = try TesseraeJSON.encoder().encode(draft.patch)
    #expect(try TesseraeJSON.decoder().decode(DashboardSettingsPatch.self, from: encoded) == expected)
  }

  @Test func realServerChoicesCorrelateToScopedFieldAndPreservePagination() throws {
    let detail = try TesseraeJSON.decoder().decode(DashboardSettings.self,
      from: serverFixture("dashboard-component-settings-response.json"))
    let choices = try TesseraeJSON.decoder().decode(DashboardSettingChoices.self,
      from: serverFixture("dashboard-settings-choices-response.json"))
    let field = try #require(detail.components.flatMap(\.fields).first { $0.id == choices.fieldID })
    #expect(field.type == "select" && field.choicesDynamic)
    #expect(choices.schemaRevision == detail.schemaRevision)
    #expect(choices.status == "ready")
    #expect(choices.choices == [.init(value: .string("a"), label: "Alpha")])
    #expect(choices.total == 2 && choices.offset == 0 && choices.limit == 1)
    #expect(choices.nextOffset == 1 && choices.message == nil)
    let encoded = try TesseraeJSON.encoder().encode(choices)
    #expect(try TesseraeJSON.decoder().decode(DashboardSettingChoices.self, from: encoded) == choices)
  }

  @Test func contractMetadataAndSecretsDecodeSafely() throws {
    let detail = try fixture()
    let component = try #require(detail.components.first)
    #expect(component.widget == "album_art")
    #expect(component.available)
    #expect(component.fragment == "cover")
    #expect(detail.coverage?.readonlyFields == 1)
    #expect(component.fields[0].choicesDynamic)
    #expect(component.fields[1].usingDefault)
    #expect(component.fields[1].min == 1)
    #expect(component.fields[1].max == 30)
    #expect(component.fields[2].value == nil)
    #expect(component.fields[2].defaultValue == nil)
    #expect(component.fields[2].choices.isEmpty)
    #expect(component.fields[3].isSupported == false)
    #expect(!DashboardSettingsDraft(detail).hasChanges)
    let encoded = String(decoding: try TesseraeJSON.encoder().encode(detail), as: UTF8.self)
    #expect(!encoded.contains("must-not-appear"))
  }

  @Test func defaultsMixedValuesClearResetAndRestoreStayDistinct() throws {
    let detail = try fixture()
    var draft = DashboardSettingsDraft(detail)
    let count = detail.components[0].fields[1]
    #expect(draft.value(for: count, component: true) == .number(8))
    #expect(draft.patch.componentValues.isEmpty)
    draft.setValue(.null, for: count, component: true)
    #expect(draft.patch.componentValues[count.id] == .null)
    draft.restore(count, component: true)
    #expect(!draft.hasChanges)
    let players = detail.components[0].fields[0]
    draft.reset(players, component: true)
    #expect(draft.value(for: players, component: true) == .array([]))
    #expect(draft.patch.componentValues.isEmpty)
    #expect(draft.patch.resetFields == [players.id])
    draft.setValue(.array([.string("kitchen"), .string("offline")]), for: players, component: true)
    #expect(draft.patch.resetFields.isEmpty)
    #expect(draft.patch.componentValues[players.id] == .array([.string("kitchen"), .string("offline")]))
    draft.restore(players, component: true)
    let shared = try #require(detail.inputs.first)
    #expect(shared.mixed)
    #expect(draft.value(for: shared) == nil)
    draft.setValue(.string("Unified"), for: shared)
    #expect(draft.patch.inputs == ["shared": .string("Unified")])
    draft.reset(shared)
    #expect(draft.patch.inputs.isEmpty)
    #expect(draft.patch.resetFields == ["input-shared"])
    draft.restore(shared)
    #expect(!draft.hasChanges)
  }

  @Test func oldServerPatchOmitsExtensionKeys() throws {
    let patch = DashboardSettingsPatch(revision: "old", settings: ["name": .string("New")], inputs: [:])
    let body = try #require(JSONSerialization.jsonObject(with: TesseraeJSON.encoder().encode(patch)) as? [String: Any])
    #expect(body["schema_revision"] == nil)
    #expect(body["component_values"] == nil)
    #expect(body["reset_fields"] == nil)
    let oldFixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Contracts/Fixtures/dashboard-settings-response.json").standardizedFileURL
    var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: oldFixture)) as? [String: Any])
    json.removeValue(forKey: "schema_revision")
    json.removeValue(forKey: "components")
    json.removeValue(forKey: "coverage")
    let detail = try TesseraeJSON.decoder().decode(DashboardSettings.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(detail.components.isEmpty)
    #expect(detail.schemaRevision == nil)
    #expect(!DashboardSettingsDraft(detail).hasChanges)
  }

  @Test func componentPatchEncodesOpaqueKeysAndResetWithoutValues() throws {
    let detail = try fixture()
    var draft = DashboardSettingsDraft(detail)
    draft.reset(detail.components[0].fields[0], component: true)
    draft.setValue(.null, for: detail.components[0].fields[2], component: true)
    let body = try #require(JSONSerialization.jsonObject(with: TesseraeJSON.encoder().encode(draft.patch)) as? [String: Any])
    #expect(body["schema_revision"] as? String == "schema-1")
    #expect(body["reset_fields"] as? [String] == ["field-players"])
    let values = try #require(body["component_values"] as? [String: Any])
    #expect(values["field-secret"] is NSNull)
    #expect(values.count == 1)
  }

  @Test(arguments: ["var(--accent)", "red", "#abc", "#11223344"])
  func demoRejectsNonHexColorWithoutSavingOtherEdits(color: String) async throws {
    let client = MockTesseraeClient(latency: .zero)
    let original = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    var draft = DashboardSettingsDraft(original)
    draft.settings["name"] = .string("Must not save")
    draft.componentValues["demo-weather-color"] = .string(color)
    await #expect(throws: DashboardSettingsValidationError.self) {
      _ = try await client.updateDashboardSettings(id: "pantry", patch: draft.patch, instance: instance)
    }
    #expect(try await client.fetchDashboardSettings(id: "pantry", instance: instance) == original)
  }

  @Test func demoPersistsOrderedSelectionAndOtherComponentRemainsIntact() async throws {
    let client = MockTesseraeClient(latency: .zero)
    let original = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    let players = try #require(original.components.flatMap(\.fields).first { $0.name == "entities" })
    var draft = DashboardSettingsDraft(original)
    let order: DashboardSettingValue = .array([.string("media_player.kitchen"), .string("media_player.living_room")])
    draft.setValue(order, for: players, component: true)
    let saved = try await client.updateDashboardSettings(id: "pantry", patch: draft.patch, instance: instance)
    #expect(saved.components[0] == original.components[0])
    #expect(saved.components[1].fields[0].value == order)
    #expect(saved.settings == original.settings)
    #expect(saved.inputs == original.inputs)
    #expect(try await client.fetchDashboardSettings(id: "pantry", instance: instance) == saved)
    var reset = DashboardSettingsDraft(saved)
    reset.reset(saved.components[1].fields[0], component: true)
    let restored = try await client.updateDashboardSettings(id: "pantry", patch: reset.patch, instance: instance)
    #expect(restored.components[1].fields[0].value == .array([]))
    #expect(restored.components[1].fields[0].hasOverride == false)
  }

  @Test func invalidComponentRejectsWholeSaveAndSchemaConflicts() async throws {
    let client = MockTesseraeClient(latency: .zero)
    let original = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    var draft = DashboardSettingsDraft(original)
    draft.settings["name"] = .string("Must not save")
    draft.componentValues["demo-reminders-count"] = .number(99)
    await #expect(throws: DashboardSettingsValidationError.self) {
      try await client.updateDashboardSettings(id: "pantry", patch: draft.patch, instance: instance)
    }
    #expect(try await client.fetchDashboardSettings(id: "pantry", instance: instance) == original)
    do {
      _ = try await client.updateDashboardSettings(id: "pantry", patch: .init(revision: original.revision,
        settings: [:], inputs: [:], schemaRevision: "stale", componentValues: ["demo-reminders-count": .number(10)]), instance: instance)
      Issue.record("Expected schema conflict")
    } catch let error as TesseraeClientError {
      if case .server(code: "schema_conflict", message: _, requestID: _) = error {} else { Issue.record("Wrong error") }
    }
  }

  @Test func dynamicChoicesSearchAndPaginationAreDeterministic() async throws {
    let client = MockTesseraeClient(latency: .zero)
    let first = try await client.fetchDashboardSettingChoices(id: "pantry", fieldID: "demo-album-players",
      query: "", limit: 2, offset: 0, instance: instance)
    #expect(first.choices.map(\.label) == ["Living Room", "Kitchen"])
    #expect(first.nextOffset == 2)
    let next = try await client.fetchDashboardSettingChoices(id: "pantry", fieldID: "demo-album-players",
      query: "", limit: 2, offset: try #require(first.nextOffset), schemaRevision: first.schemaRevision, instance: instance)
    #expect(next.choices.map(\.label) == ["Bedroom", "Office"])
    #expect(next.nextOffset == nil)
    let search = try await client.fetchDashboardSettingChoices(id: "pantry", fieldID: "demo-album-players",
      query: "KIT", limit: 2, offset: 0, instance: instance)
    #expect(search.choices.map(\.label) == ["Kitchen"])
    #expect(search.total == 1)
  }

  @Test(arguments: ["ready", "unavailable"])
  func choicesRequestUsesScopedEndpointAndDistinguishesProviderFailure(status: String) async throws {
    let body = Data("""
    {"field_id":"opaque-field","schema_revision":"schema-1","status":"\(status)","choices":[],
     "total":0,"offset":5,"limit":10,"has_more":false,"message":null}
    """.utf8)
    let transport = ComponentChoiceTransport(body: body)
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: "test-token", for: instance.id)
    let client = LiveTesseraeClient(credentials: credentials,
      identity: .init(appVersion: "test", installationID: "test"), transport: transport)
    let result = try await client.fetchDashboardSettingChoices(id: "pantry", fieldID: "opaque-field",
      query: "A & B", limit: 10, offset: 5, schemaRevision: "schema-1", instance: instance)
    #expect(result.status == status)
    let request = try #require(await transport.request)
    #expect(request.url?.path == "/api/app/v1/dashboards/pantry/settings/fields/opaque-field/choices")
    let url = try #require(request.url)
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.first { $0.name == "q" }?.value == "A & B")
    #expect(query.first { $0.name == "schema_revision" }?.value == "schema-1")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "X-Tesserae-Dashboard-Controls") == "1")
  }
}

private actor ComponentChoiceTransport: TesseraeHTTPTransporting {
  let body: Data
  var request: URLRequest?
  init(body: Data) { self.body = body }
  func send(_ request: URLRequest) -> TesseraeHTTPResponse {
    self.request = request
    return .init(data: body, statusCode: 200)
  }
}
