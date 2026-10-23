import Foundation
import TesseraeKit
import Testing

@testable import Tesserae_Companion

@MainActor
struct DashboardSettingsAppModelTests {
  private func model() async -> AppModel {
    let client = MockTesseraeClient(latency: .zero)
    let result = AppModel(
      liveClient: client, demoClient: client,
      credentials: InMemoryCredentialStore(), stateStore: InMemoryCompanionStateStore(),
      sendPreferences: InMemoryCompanionSendPreferencesStore(),
      shareQueue: InMemoryShareQueueStore(),
      linkShareQueue: InMemoryLinkShareQueueStore(),
      activityThumbnails: InMemoryActivityThumbnailStore(),
      discovery: StaticDiscoveryService(results: []))
    await result.connectDemo()
    return result
  }
  @Test func saveUpdatesEveryOccurrenceAndInvalidatesPreviewWithoutPushing() async throws {
    let model = await model()
    let source = try #require(model.dashboards.first { $0.id == "pantry" })
    await model.loadDashboardPreview(id: source.id, deviceID: source.deviceIDs.first)
    let generation = model.previewGeneration
    let detail = try await model.fetchDashboardSettings(source.id)
    var draft = DashboardSettingsDraft(detail)
    draft.settings["name"] = .string("Updated Dashboard")
    draft.settings["device_ids"] = .array([.string("e1004-desk")])
    _ = try await model.saveDashboardSettings(source.id, patch: draft.patch)
    let updated = try #require(model.dashboards.first { $0.id == source.id })
    #expect(updated.name == "Updated Dashboard")
    #expect(updated.deviceIDs == ["e1004-desk"])
    #expect(model.previewGeneration > generation)
    #expect(model.dashboardPreview(for: source, deviceID: source.deviceIDs.first) == nil)
    #expect(model.jobs.isEmpty)
  }
  @Test func conflictPreservesAcceptedListAndRetryDraft() async throws {
    let model = await model()
    let original = try await model.fetchDashboardSettings("pantry")
    var first = DashboardSettingsDraft(original)
    first.settings["name"] = .string("First edit")
    var stale = DashboardSettingsDraft(original)
    stale.settings["name"] = .string("Stale edit")
    _ = try await model.saveDashboardSettings("pantry", patch: first.patch)
    await #expect(throws: TesseraeClientError.self) {
      try await model.saveDashboardSettings("pantry", patch: stale.patch)
    }
    #expect(model.dashboards.first { $0.id == "pantry" }?.name == "First edit")
    #expect(stale.hasChanges)
    #expect(stale.settings["name"] == .string("Stale edit"))
    #expect(model.jobs.isEmpty)
  }
  @Test func unsupportedServerMakesNoSettingsRequest() async throws {
    let model = await model()
    model.capabilities = nil
    #expect(!model.supportsDashboardSettings)
    await #expect(throws: TesseraeClientError.unavailable) {
      try await model.fetchDashboardSettings("pantry")
    }
  }

  @Test func componentDraftSavePreservesOtherComponentsAndDoesNotPush() async throws {
    let model = await model()
    #expect(model.supportsDashboardComponentSettings)
    let original = try await model.fetchDashboardSettings("pantry")
    let reminders = try #require(original.components.first { $0.id == "demo-reminders" })
    let title = try #require(reminders.fields.first { $0.name == "title" })
    var draft = DashboardSettingsDraft(original)
    draft.setValue(.string("Groceries for tonight"), for: title, component: true)
    _ = try await model.saveDashboardSettings("pantry", patch: draft.patch)
    let reloaded = try await model.fetchDashboardSettings("pantry")
    #expect(reloaded.components.first { $0.id == reminders.id }?.fields.first { $0.name == "title" }?.value
      == .string("Groceries for tonight"))
    #expect(reloaded.components.first { $0.id == "demo-album" }
      == original.components.first { $0.id == "demo-album" })
    #expect(model.jobs.isEmpty)
    let choices = try await model.fetchDashboardSettingChoices(
      "pantry", fieldID: "demo-reminders-list", query: "Work", offset: 0,
      schemaRevision: reloaded.schemaRevision)
    #expect(choices.status == "ready")
    #expect(choices.choices.map(\.label) == ["Work"])
  }
}
