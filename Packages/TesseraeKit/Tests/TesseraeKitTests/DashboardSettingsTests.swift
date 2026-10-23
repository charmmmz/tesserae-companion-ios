import Foundation
import Testing

@testable import TesseraeKit

struct DashboardSettingsTests {
  private var instance: TesseraeInstance {
    .init(
      id: "home", name: "Home", baseURL: URL(string: "https://tesserae.example")!,
      serverVersion: "0.472.0", timezone: "Asia/Shanghai", webURL: "/")
  }
  private func fixture() throws -> Data {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .appending(path: "../../../../Contracts/Fixtures/dashboard-settings-response.json")
      .standardizedFileURL
    return try Data(contentsOf: url)
  }
  @Test func serverFixtureAndUntouchedSecrets() throws {
    let result = try TesseraeJSON.decoder().decode(DashboardSettings.self, from: fixture())
    #expect(result.dashboardID == "pantry")
    #expect(result.settings["device_ids"] == .array([.string("kitchen")]))
    #expect(result.inputs.last?.configured == true)
    #expect(result.inputs.last?.value == nil)
    #expect(!DashboardSettingsDraft(result).hasChanges)
    var draft = DashboardSettingsDraft(result)
    draft.settings["name"] = .string("New name")
    #expect(draft.patch.settings == ["name": .string("New name")])
    #expect(draft.patch.inputs.isEmpty)
  }
  @Test func explicitClearAndPreserveUseDifferentPayloads() throws {
    var draft = DashboardSettingsDraft(
      try TesseraeJSON.decoder().decode(DashboardSettings.self, from: fixture()))
    draft.inputs["token"] = .string("replacement")
    #expect(draft.patch.inputs["token"] == .string("replacement"))
    draft.inputs["token"] = .null
    draft.settings["sleep_interval_s"] = .null
    let body = try #require(
      JSONSerialization.jsonObject(with: TesseraeJSON.encoder().encode(draft.patch))
        as? [String: Any])
    #expect((body["inputs"] as? [String: Any])?["token"] is NSNull)
    #expect((body["settings"] as? [String: Any])?["sleep_interval_s"] is NSNull)
    draft.inputs["token"] = nil
    #expect(draft.patch.inputs.isEmpty)
  }
  @Test func unsupportedFieldRemainsIntact() throws {
    var body = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
    var inputs = try #require(body["inputs"] as? [[String: Any]])
    inputs[0]["type"] = "future-control"
    inputs[0]["editable"] = false
    inputs[0]["value"] = ["nested": ["data"]]
    body["inputs"] = inputs
    let result = try TesseraeJSON.decoder().decode(
      DashboardSettings.self, from: JSONSerialization.data(withJSONObject: body))
    #expect(result.inputs.first?.isSupported == false)
    var draft = DashboardSettingsDraft(result)
    draft.settings["refresh_minutes"] = .number(60)
    #expect(draft.patch.inputs.isEmpty)
  }
  @Test func duplicateDeclarationsAreReadOnlyAndDoNotCrashDraft() throws {
    var body = try #require(JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
    var inputs = try #require(body["inputs"] as? [[String: Any]])
    var duplicate = inputs[0]
    duplicate["secret"] = true
    duplicate.removeValue(forKey: "value")
    inputs.append(duplicate)
    body["inputs"] = inputs
    let result = try TesseraeJSON.decoder().decode(
      DashboardSettings.self, from: JSONSerialization.data(withJSONObject: body))
    #expect(result.displayInputs.count == 2)
    #expect(result.displayInputs.first?.editable == false)
    #expect(result.displayInputs.first?.secret == true)
    #expect(result.displayInputs.first?.value == nil)
    #expect(!DashboardSettingsDraft(result).hasChanges)
  }

  @Test func textEditingPreservesPrecisionAndAllowsOptionalNumericClear() {
    let field = DashboardSettingInput(
      name: "n", label: "Number", type: "number", required: false, help: "", choices: [],
      secret: false, editable: true, configured: true, value: .number(2))
    #expect(field.value(from: "") == .null)
    #expect(field.value(from: "1.25") == .number(1.25))
    #expect(field.value(from: "-") == .string("-"))
    #expect(Double(DashboardSettingValue.number(1.23456789123).settingText) == 1.23456789123)
    let secret = DashboardSettingInput(
      name: "s", label: "Secret", type: "string", required: false, help: "", choices: [],
      secret: true, editable: true, configured: true, value: nil)
    #expect(secret.value(from: "") == nil)
  }

  @Test func clientUsesScopedGetAndPartialPatch() async throws {
    let transport = DashboardSettingsTransport(
      response: .init(data: try fixture(), statusCode: 200))
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: "test-token", for: instance.id)
    let client = LiveTesseraeClient(
      credentials: credentials, identity: .init(appVersion: "test", installationID: "test"),
      transport: transport)
    let settings = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    var draft = DashboardSettingsDraft(settings)
    draft.settings["refresh_minutes"] = .number(15)
    draft.settings["sleep_interval_s"] = .number(60)
    _ = try await client.updateDashboardSettings(
      id: "pantry", patch: draft.patch, instance: instance)
    let requests = await transport.requests
    #expect(requests.map(\.httpMethod) == ["GET", "PATCH"])
    #expect(requests.last?.url?.path == "/api/app/v1/dashboards/pantry/settings")
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    let data = try #require(requests.last?.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(body["revision"] as? String == settings.revision)
    let patch = try #require(body["settings"] as? [String: Any])
    #expect(patch.count == 1)
    // Integral values must encode as JSON integers, accepted by the Python strict validator.
    #expect(String(decoding: data, as: UTF8.self).contains("60.0") == false)
  }
  @Test(arguments: [403, 409]) func authorizationAndConflictStayDistinct(status: Int) async throws {
    let body = Data(#"{"error":{"code":"revision_conflict","message":"Changed elsewhere"}}"#.utf8)
    let transport = DashboardSettingsTransport(response: .init(data: body, statusCode: status))
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: "test", for: instance.id)
    let client = LiveTesseraeClient(
      credentials: credentials, identity: .init(appVersion: "test", installationID: "test"),
      transport: transport)
    do {
      _ = try await client.updateDashboardSettings(
        id: "pantry",
        patch: .init(revision: "old", settings: ["name": .string("new")], inputs: [:]),
        instance: instance)
      Issue.record("Expected save failure")
    } catch let error as TesseraeClientError {
      if status == 403 {
        if case .forbidden = error {} else { Issue.record("Expected permission failure") }
      } else {
        if case .server(code: "revision_conflict", message: _, requestID: _) = error {
        } else {
          Issue.record("Expected conflict")
        }
      }
    }
  }
  @Test func validationRetainsFieldNames() async throws {
    let body = Data(
      #"{"error":{"code":"invalid_request","message":"Invalid settings","fields":{"settings.name":"Required"}}}"#
        .utf8)
    let transport = DashboardSettingsTransport(response: .init(data: body, statusCode: 400))
    let credentials = InMemoryCredentialStore()
    await credentials.save(token: "test", for: instance.id)
    let client = LiveTesseraeClient(
      credentials: credentials, identity: .init(appVersion: "test", installationID: "test"),
      transport: transport)
    do {
      _ = try await client.updateDashboardSettings(
        id: "pantry", patch: .init(revision: "old", settings: ["name": .string("")], inputs: [:]),
        instance: instance)
      Issue.record("Expected validation failure")
    } catch let error as DashboardSettingsValidationError {
      #expect(error.fields["settings.name"] == "Required")
    }
  }
  @Test func demoSavePersistsAndStaleDraftConflicts() async throws {
    let client = MockTesseraeClient(latency: .zero)
    let settings = try await client.fetchDashboardSettings(id: "pantry", instance: instance)
    var draft = DashboardSettingsDraft(settings)
    draft.settings["name"] = .string("Dinner")
    let saved = try await client.updateDashboardSettings(
      id: "pantry", patch: draft.patch, instance: instance)
    #expect(saved.revision != settings.revision)
    #expect(
      try await client.fetchDashboards(instance: instance).first { $0.id == "pantry" }?.name
        == "Dinner")
    await #expect(throws: TesseraeClientError.self) {
      try await client.updateDashboardSettings(id: "pantry", patch: draft.patch, instance: instance)
    }
  }
}

private actor DashboardSettingsTransport: TesseraeHTTPTransporting {
  let response: TesseraeHTTPResponse
  var requests: [URLRequest] = []
  init(response: TesseraeHTTPResponse) { self.response = response }
  func send(_ request: URLRequest) -> TesseraeHTTPResponse {
    requests.append(request)
    return response
  }
}
