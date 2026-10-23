import Foundation
import Testing

@testable import TesseraeKit

/// Opt in against an isolated, seeded development server, never a household instance.
struct DashboardSettingsHTTPIntegrationTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["TESSERAE_DASHBOARD_HTTP_TEST"] == "1"))
  func pythonServerRoundTrip() async throws {
    struct Configuration: Decodable {
      let url: URL
      let token: String
    }
    let config = try JSONDecoder().decode(
      Configuration.self,
      from: Data(contentsOf: URL(fileURLWithPath: "/tmp/tesserae-dashboard-integration.json")))
    #expect(config.url.host == "127.0.0.1")
    let instance = TesseraeInstance(
      id: "isolated-dashboard-test", name: "Test", baseURL: config.url, serverVersion: "dev",
      timezone: "UTC", webURL: config.url.absoluteString)
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: config.token, for: instance.id)
    let client = LiveTesseraeClient(
      credentials: credentials,
      identity: .init(appVersion: "integration", installationID: "integration"))
    let capabilities = try await client.probe(baseURL: config.url)
    #expect(capabilities.features.contains("dashboard_settings"))
    let original = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    #expect(original.canEdit)
    var draft = DashboardSettingsDraft(original)
    draft.settings["name"] = .string("Swift HTTP round trip")
    draft.settings["icon"] = .string("calendar")
    draft.settings["refresh_minutes"] = .number(45)
    draft.settings["sleep_interval_s"] = .number(600)
    draft.settings["device_ids"] = .array([.string("kitchen")])
    draft.inputs["location"] = .string("Shanghai")
    draft.inputs["count"] = .number(7)
    draft.inputs["enabled"] = .bool(true)
    draft.inputs["choice"] = .string("b")
    let saved = try await client.updateDashboardSettings(
      id: "pantry", patch: draft.patch, instance: instance)
    #expect(saved.settings["name"] == .string("Swift HTTP round trip"))
    #expect(saved.inputs.first { $0.name == "count" }?.value == .number(7))
    #expect(saved.inputs.first { $0.name == "token" }?.configured == true)
    #expect(saved.inputs.first { $0.name == "token" }?.value == nil)
    let reread = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    #expect(reread == saved)
    do {
      _ = try await client.updateDashboardSettings(
        id: "pantry", patch: draft.patch, instance: instance)
      Issue.record("Stale write must conflict")
    } catch let error as TesseraeClientError {
      if case .server(code: "revision_conflict", message: _, requestID: _) = error {
      } else {
        Issue.record("Wrong conflict response: \(error)")
      }
    }
    var clear = DashboardSettingsDraft(saved)
    clear.settings["sleep_interval_s"] = .null
    clear.inputs["count"] = .null
    let cleared = try await client.updateDashboardSettings(
      id: "pantry", patch: clear.patch, instance: instance)
    #expect(cleared.settings["sleep_interval_s"] == .null)
    #expect(cleared.inputs.first { $0.name == "count" }?.configured == false)
  }
}
