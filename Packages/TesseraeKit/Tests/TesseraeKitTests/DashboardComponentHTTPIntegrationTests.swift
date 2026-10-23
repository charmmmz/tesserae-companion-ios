import Foundation
import Testing

@testable import TesseraeKit

/// Explicit opt-in: an isolated fixture or unbound QA copy, reached through localhost.
struct DashboardComponentHTTPIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_COMPONENT_HTTP_TEST"] == "1"))
  func componentRoundTrip() async throws {
    struct Configuration: Decodable {
      let url: URL
      let token: String
      let dashboardID: String
      enum CodingKeys: String, CodingKey { case url, token; case dashboardID = "dashboard_id" }
    }
    let config = try JSONDecoder().decode(Configuration.self,
      from: Data(contentsOf: URL(fileURLWithPath: "/tmp/tesserae-dashboard-component-integration.json")))
    try #require(config.url.host == "127.0.0.1")
    let instance = TesseraeInstance(id: "component-http-qa", name: "QA", baseURL: config.url,
      serverVersion: "dev", timezone: "UTC", webURL: config.url.absoluteString)
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: config.token, for: instance.id)
    let client = LiveTesseraeClient(credentials: credentials,
      identity: .init(appVersion: "integration", installationID: "component-integration"))
    let capabilities = try await client.probe(baseURL: config.url)
    #expect(capabilities.features.contains("dashboard_component_settings"))
    let original = try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance)
    try #require(original.settings["device_ids"] == .array([]))
    try #require(original.settings["name"]?.settingText.contains("QA") == true)
    try #require(original.canEdit)
    let originalFields = original.components.flatMap(\.fields)
    let selection = try #require(originalFields.first { $0.type == "select" && $0.choicesDynamic && $0.isSupported })
    let players = try #require(originalFields.first { $0.type == "multiselect" && $0.isSupported })
    let number = try #require(originalFields.first { $0.type == "number" && $0.isSupported && $0.defaultValue != nil })
    let editedFieldIDs = Set([selection.id, players.id, number.id])
    let unchangedComponents = Set(original.components.filter { component in
      !component.fields.contains { editedFieldIDs.contains($0.id) }
    }.map(\.id))
    let selectionID = try #require(selection.fieldID)
    let playersID = try #require(players.fieldID)
    let numberID = try #require(number.fieldID)
    let page = try await client.fetchDashboardSettingChoices(id: config.dashboardID, fieldID: selectionID,
      query: "", limit: 1, offset: 0, schemaRevision: original.schemaRevision, instance: instance)
    #expect(page.status == "ready")
    let nextOffset = try #require(page.nextOffset)
    let next = try await client.fetchDashboardSettingChoices(id: config.dashboardID, fieldID: selectionID,
      query: "", limit: 1, offset: nextOffset, schemaRevision: original.schemaRevision, instance: instance)
    let choice = try #require(next.choices.first)
    #expect(page.choices.first?.value != choice.value)
    let search = try await client.fetchDashboardSettingChoices(id: config.dashboardID, fieldID: selectionID,
      query: choice.label, limit: 50, offset: 0, schemaRevision: original.schemaRevision, instance: instance)
    #expect(search.choices.contains { $0.value == choice.value })
    let playerChoices = try await client.fetchDashboardSettingChoices(id: config.dashboardID, fieldID: playersID,
      query: "", limit: 50, offset: 0, schemaRevision: original.schemaRevision, instance: instance)
    try #require(playerChoices.choices.count >= 2)
    let ordered = DashboardSettingValue.array(playerChoices.choices.prefix(2).reversed().map(\.value))
    var draft = DashboardSettingsDraft(original)
    draft.settings["name"] = .string("Dashboard Component HTTP QA Updated")
    draft.setValue(choice.value, for: selection, component: true)
    draft.setValue(ordered, for: players, component: true)
    let numericValue = min(number.max ?? 10, max(number.min ?? 1, 3))
    draft.setValue(.number(numericValue), for: number, component: true)
    let saved = try await client.updateDashboardSettings(id: config.dashboardID, patch: draft.patch, instance: instance)
    let fields = saved.components.flatMap(\.fields)
    #expect(fields.first { $0.id == selectionID }?.value == choice.value)
    #expect(fields.first { $0.id == playersID }?.value == ordered)
    #expect(fields.first { $0.id == numberID }?.value == .number(numericValue))
    #expect(saved.components.filter { unchangedComponents.contains($0.id) } == original.components.filter { unchangedComponents.contains($0.id) })
    #expect(saved.inputs == original.inputs)
    #expect(try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance) == saved)
    do {
      _ = try await client.updateDashboardSettings(id: config.dashboardID, patch: draft.patch, instance: instance)
      Issue.record("Stale writes must conflict")
    } catch let error as TesseraeClientError {
      if case .server(code: "revision_conflict", message: _, requestID: _) = error {} else { Issue.record("Wrong conflict") }
    }
    do {
      _ = try await client.updateDashboardSettings(id: config.dashboardID,
        patch: .init(revision: saved.revision, settings: ["name": .string("Invalid schema")], inputs: [:],
          schemaRevision: "stale-schema"), instance: instance)
      Issue.record("Schema changes must conflict")
    } catch let error as TesseraeClientError {
      if case .server(code: "schema_conflict", message: _, requestID: _) = error {} else { Issue.record("Wrong schema conflict") }
    }
    var invalid = DashboardSettingsDraft(saved)
    invalid.settings["name"] = .string("Must not be saved")
    invalid.componentValues[numberID] = .string("invalid-number")
    await #expect(throws: DashboardSettingsValidationError.self) {
      try await client.updateDashboardSettings(id: config.dashboardID, patch: invalid.patch, instance: instance)
    }
    #expect(try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance) == saved)
    var clear = DashboardSettingsDraft(saved)
    let savedNumber = try #require(fields.first { $0.id == numberID })
    clear.setValue(.null, for: savedNumber, component: true)
    let cleared = try await client.updateDashboardSettings(id: config.dashboardID, patch: clear.patch, instance: instance)
    let clearedNumber = try #require(cleared.components.flatMap(\.fields).first { $0.id == numberID })
    #expect(clearedNumber.value == .null)
    #expect(clearedNumber.hasOverride)
    var reset = DashboardSettingsDraft(cleared)
    reset.reset(clearedNumber, component: true)
    let resetResult = try await client.updateDashboardSettings(id: config.dashboardID, patch: reset.patch, instance: instance)
    let resetNumber = try #require(resetResult.components.flatMap(\.fields).first { $0.id == numberID })
    #expect(resetNumber.value == number.defaultValue)
    #expect(!resetNumber.hasOverride)
    #expect(try await client.fetchDashboardSettings(id: config.dashboardID, instance: instance) == resetResult)
  }
}
