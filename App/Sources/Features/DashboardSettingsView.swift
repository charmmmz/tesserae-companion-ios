import SwiftUI
import TesseraeKit

struct DashboardSettingsView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @Environment(\.scenePhase) private var scenePhase
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let dashboardID: String
  @ScaledMetric(relativeTo: .body) private var numberFieldWidth: CGFloat = 90
  @State private var draft: DashboardSettingsDraft?
  @State private var isLoading = false
  @State private var isSaving = false
  @State private var error: String?
  @State private var fieldErrors: [String: String] = [:]
  @State private var conflict = false
  @State private var confirmDiscard = false
  @State private var discardForReload = false
  @State private var pushTarget: DashboardSummary?
  @State private var saved = false
  @State private var numberText: [String: String] = [:]
  @State private var writeDenied = false

  private var dashboard: DashboardSummary? { model.dashboards.first { $0.id == dashboardID } }
  private var dirty: Bool { draft?.hasChanges == true }
  private var canEdit: Bool {
    draft?.original.canEdit == true && !isSaving && !isLoading && !writeDenied
  }
  private var previewDeviceID: String? { dashboard?.deviceIDs.first }
  private var webURL: URL? {
    guard let base = model.activeInstance?.baseURL else { return nil }
    return dashboardWebURL(draft?.original.webURL ?? dashboard?.webURL, relativeTo: base)
  }

  var body: some View {
    Form {
      overview
      if isLoading && draft == nil {
        ProgressView().frame(maxWidth: .infinity)
      }
      if let error {
        Section {
          Text(error).foregroundStyle(.red).accessibilityIdentifier("dashboard-settings-error")
          if conflict {
            Text("This Dashboard changed elsewhere. Reload its settings before saving again.")
          }
          Button("Reload Settings") { requestReload() }
        }
      }
      if let current = draft {
        if !current.original.canEdit || writeDenied {
          Section {
            Text(
              "Editing requires permission in Tesserae Settings. Grant Dashboard editing to this app, then reload."
            )
            Button("Reload Settings") { requestReload() }
          }
        }
        generalSettings.disabled(!canEdit)
        configurationSettings
        preferences
      } else if !model.supportsDashboardSettings {
        Section {
          Text(
            "This server does not support native Dashboard settings yet. Open this Dashboard in Tesserae to edit it."
          )
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(dashboard?.name ?? String(localized: "Dashboard Settings"))
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(dirty || isSaving)
    .toolbar {
      if dirty || isSaving {
        ToolbarItem(placement: .topBarLeading) {
          Button {
            discardForReload = false
            confirmDiscard = true
          } label: {
            Label("Back", systemImage: "chevron.left")
          }.disabled(isSaving)
        }
      }
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Button("Reload Settings", systemImage: "arrow.clockwise") { requestReload() }
            .disabled(isSaving || isLoading)
          if let webURL {
            Link(destination: webURL) { Label("Open in Tesserae", systemImage: "safari") }
          }
        } label: {
          Label("More", systemImage: "ellipsis")
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        if draft?.original.canEdit == true {
          Button {
            Task { await save() }
          } label: {
            if isSaving {
              ProgressView().accessibilityLabel("Save")
            } else {
              Label("Save", systemImage: "checkmark").labelStyle(.iconOnly)
            }
          }
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .accessibilityLabel("Save")
          .disabled(!dirty || !canEdit || conflict)
          .accessibilityIdentifier("dashboard-settings-save")
        }
      }
    }
    .alert("Discard Changes?", isPresented: $confirmDiscard) {
      Button("Discard Changes", role: .destructive) {
        if discardForReload { Task { await load() } } else { dismiss() }
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("Your changes haven’t been saved.")
    }
    .sheet(item: $pushTarget) { target in
      DashboardPreviewActionSheet(
        dashboardID: target.id, dashboardName: target.name,
        previewDeviceID: target.deviceIDs.first, displays: model.sortedDisplays,
        initialDeviceIDs: Set(target.deviceIDs), showsDisplayPicker: true, action: .push(target))
    }
    .task { if draft == nil { await load() } }
    .task(id: model.previewGeneration) {
      await model.loadDashboardPreview(id: dashboardID, deviceID: previewDeviceID)
    }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active && !dirty && !isSaving { Task { await load() } }
    }
    .refreshable { requestReload() }
    .onChange(of: dirty) { _, changed in if changed { saved = false } }
    .accessibilityIdentifier("dashboard-settings-detail")
  }

  private var overview: some View {
    Section {
      if let dashboard {
        PreviewArtwork(
          state: model.dashboardPreview(for: dashboard, deviceID: previewDeviceID),
          placeholderSystemName: "rectangle", placeholderLabel: "Dashboard preview placeholder",
          imageLabel: "Dashboard preview", accessibilityIdentifier: "dashboard-settings-preview"
        )
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .overlay(alignment: .topTrailing) {
          Button {
            pushTarget = dashboard
          } label: {
            Label("Push", systemImage: "paperplane.fill")
              .labelStyle(.iconOnly)
              .font(.body.weight(.semibold))
              .frame(width: 44, height: 44)
              .background(.regularMaterial, in: Circle())
              .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
          }
          .buttonStyle(.plain)
          .disabled(dirty || isSaving)
          .accessibilityIdentifier("dashboard-settings-push")
          .padding(10)
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }
      if saved { Label("Settings saved", systemImage: "checkmark.circle").foregroundStyle(.green) }
    } footer: {
      if dirty { Text("Save your changes before pushing.") }
    }
  }

  private var preferences: some View {
    Section("Preferences") {
      NavigationLink {
        Form { displaySettings.disabled(!canEdit) }
          .navigationTitle("Displays").navigationBarTitleDisplayMode(.inline)
      } label: {
        Label("Displays", systemImage: "display")
      }
      .accessibilityIdentifier("dashboard-settings-displays")
      NavigationLink {
        Form { cadenceSettings.disabled(!canEdit) }
          .navigationTitle("Updates").navigationBarTitleDisplayMode(.inline)
      } label: {
        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
      }
      .accessibilityIdentifier("dashboard-settings-updates")
      NavigationLink {
        Form { appearanceSettings.disabled(!canEdit) }
          .navigationTitle("Appearance").navigationBarTitleDisplayMode(.inline)
      } label: {
        Label("Appearance", systemImage: "paintpalette")
      }
      .accessibilityIdentifier("dashboard-settings-appearance")
    }
  }

  @ViewBuilder private var configurationSettings: some View {
    if let binding = Binding($draft) {
      let current = binding.wrappedValue
      if !current.original.displayInputs.isEmpty {
        Section("Dashboard Configuration") {
          ForEach(current.original.displayInputs) { input in
            DashboardSettingsField(
              dashboardID: dashboardID, input: input, draft: binding,
              component: false, canEdit: canEdit,
              error: fieldErrors["inputs.\(input.name)"]
                ?? input.fieldID.flatMap { fieldErrors["reset_fields.\($0)"] }, webURL: webURL
            )
            .id("\(input.id)|\(current.original.revision)")
          }
        }
      }
      Section {
        ForEach(current.original.components) { component in
          NavigationLink {
            DashboardComponentSettingsView(
              dashboardID: dashboardID, component: component, draft: binding,
              canEdit: canEdit, fieldErrors: fieldErrors, webURL: webURL)
          } label: {
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(component.label)
                if !component.available {
                  Text("Component unavailable").font(.caption).foregroundStyle(.secondary)
                } else if let detail = component.sourceName ?? component.fragment, !detail.isEmpty {
                  Text(detail).font(.caption).foregroundStyle(.secondary)
                }
              }
              Spacer(minLength: 0)
              if component.fields.contains(where: { field in
                guard let id = field.fieldID else { return false }
                return fieldErrors["component_values.\(id)"] != nil
                  || fieldErrors["reset_fields.\(id)"] != nil
              }) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                  .accessibilityLabel("Review this component’s settings")
              } else if component.fields.contains(where: {
                current.hasChanges(for: $0, component: true)
              }) {
                Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(.tint)
                  .accessibilityLabel("Unsaved changes")
              }
            }
          }
          .accessibilityIdentifier("dashboard-component-\(component.id)")
        }
        if current.original.components.isEmpty && current.original.displayInputs.isEmpty {
          Text(
            LocalizedStringKey(
              model.supportsDashboardComponentSettings
                ? "This Dashboard has no editable content fields. Open the web editor for layout or code changes."
                : "This server has no Dashboard-level fields for this page. Component settings require a newer server."
            )
          )
          .foregroundStyle(.secondary)
        }
      } header: {
        Text("Components")
      } footer: {
        if dirty { Text("Save applies all changes.") }
      }
    }
  }

  private var generalSettings: some View {
    Section("General") {
      LabeledContent("Name") {
        TextField("Name", text: settingText("name"))
          .multilineTextAlignment(.trailing)
          .accessibilityIdentifier("dashboard-settings-name")
      }
      fieldError("settings.name")
      NavigationLink {
        DashboardIconPicker(selection: settingText("icon"))
      } label: {
        LabeledContent("Icon") {
          PhosphorIcon(name: draft?.settings["icon"]?.settingText, size: 24)
        }
      }
      .accessibilityValue(
        DashboardIconPicker.label(for: draft?.settings["icon"]?.settingText ?? "")
      )
      .accessibilityIdentifier("dashboard-settings-icon")
      fieldError("settings.icon")
    }
  }
  private var displaySettings: some View {
    Section("Displays") {
      ForEach(model.sortedDisplays) { display in
        Toggle(
          display.name,
          isOn: Binding(
            get: {
              if case .array(let ids) = draft?.settings["device_ids"] {
                return ids.contains(.string(display.id))
              }
              return false
            },
            set: { selected in
              var ids: [DashboardSettingValue] =
                if case .array(let values) = draft?.settings["device_ids"] { values } else { [] }
              ids.removeAll { $0 == .string(display.id) }
              if selected { ids.append(.string(display.id)) }
              draft?.settings["device_ids"] = .array(ids)
            }))
      }
      if case .array(let ids) = draft?.settings["device_ids"] {
        ForEach(
          ids.filter { value in !model.displays.contains { .string($0.id) == value } }, id: \.self
        ) { value in
          HStack {
            LabeledContent("Unavailable display", value: value.settingText)
            Button {
              draft?.settings["device_ids"] = .array(ids.filter { $0 != value })
            } label: {
              Image(systemName: "minus.circle")
            }.accessibilityLabel("Remove unavailable display")
          }
        }
      }
      fieldError("settings.device_ids")
    }
  }

  private var cadenceSettings: some View {
    Section {
      intervalField("refresh_minutes", title: "Content update interval (minutes)", placeholder: "0")
      fieldError("settings.refresh_minutes")
      intervalField(
        "sleep_interval_s", title: "Wake interval (seconds)", placeholder: "Default", nullable: true
      )
      fieldError("settings.sleep_interval_s")
    } header: {
      Text("Updates")
    } footer: {
      Text(
        "0 updates only on push. An empty wake interval uses the display’s default."
      )
    }
  }

  private func intervalField(
    _ key: String, title: LocalizedStringKey, placeholder: LocalizedStringKey,
    nullable: Bool = false
  ) -> some View {
    let layout =
      dynamicTypeSize.isAccessibilitySize
      ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
      : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 16))
    return layout {
      Text(title).frame(maxWidth: .infinity, alignment: .leading)
      TextField(placeholder, text: settingText(key, number: true, nullable: nullable))
        .keyboardType(.numberPad)
        .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : numberFieldWidth)
        .accessibilityLabel(title)
        .accessibilityIdentifier(
          key == "refresh_minutes"
            ? "dashboard-settings-refresh-minutes" : "dashboard-settings-wake-seconds")
    }
  }

  private var appearanceSettings: some View {
    Section("Appearance") {
      appearancePicker("theme", title: "Theme", options: "themes")
      appearancePicker("style", title: "Style", options: "styles")
      appearancePicker("font", title: "Font", options: "fonts", nullable: true)
    }
  }

  private func appearancePicker(
    _ key: String, title: LocalizedStringKey, options: String, nullable: Bool = false
  ) -> some View {
    let choices = draft?.original.options[options] ?? []
    let selected = draft?.settings[key] ?? .null
    return Group {
      Picker(
        title,
        selection: Binding(
          get: { draft?.settings[key] ?? .null }, set: { draft?.settings[key] = $0 })
      ) {
        if nullable { Text("Default").tag(DashboardSettingValue.null) }
        ForEach(choices, id: \.value) { choice in Text(choice.label).tag(choice.value) }
        if !choices.contains(where: { $0.value == selected }), selected != .null {
          Text(selected.settingText).tag(selected)
        }
      }
      fieldError("settings.\(key)")
    }
  }

  private func settingText(_ key: String, number: Bool = false, nullable: Bool = false) -> Binding<
    String
  > {
    Binding(
      get: { numberText[key] ?? draft?.settings[key]?.settingText ?? "" },
      set: { value in
        if number { numberText[key] = value }
        if nullable && value.isEmpty {
          draft?.settings[key] = .null
        } else if number, let parsed = Double(value), parsed.isFinite {
          draft?.settings[key] = .number(parsed)
        } else {
          draft?.settings[key] = .string(value)
        }
      })
  }
  @ViewBuilder private func fieldError(_ key: String) -> some View {
    if let message = fieldErrors[key] { Text(message).font(.caption).foregroundStyle(.red) }
  }
  private func requestReload() {
    guard !isSaving, !isLoading else { return }
    if dirty {
      discardForReload = true
      confirmDiscard = true
    } else {
      Task { await load() }
    }
  }
  private func load() async {
    guard model.supportsDashboardSettings, !isLoading else { return }
    isLoading = true
    defer { isLoading = false }
    do {
      let settings = try await model.fetchDashboardSettings(dashboardID)
      try Task.checkCancellation()
      draft = DashboardSettingsDraft(settings)
      error = nil
      fieldErrors = [:]
      conflict = false
      saved = false
      numberText = [:]
      writeDenied = false
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
  private func save() async {
    guard let draft, draft.hasChanges, canEdit, !conflict else { return }
    isSaving = true
    error = nil
    fieldErrors = [:]
    defer { isSaving = false }
    do {
      let result = try await model.saveDashboardSettings(dashboardID, patch: draft.patch)
      self.draft = DashboardSettingsDraft(result)
      saved = true
      numberText = [:]
      await model.loadDashboardPreview(id: dashboardID, deviceID: previewDeviceID)
    } catch let validation as DashboardSettingsValidationError {
      error = validation.message
      fieldErrors = validation.fields
    } catch let problem as TesseraeClientError {
      error = problem.localizedDescription
      if case .forbidden = problem { writeDenied = true }
      if case .server(let code, _, _) = problem {
        conflict = ["revision_conflict", "schema_conflict"].contains(code)
      }
    } catch is CancellationError {} catch { self.error = error.localizedDescription }
  }
}

private struct DashboardIconPicker: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Binding var selection: String
  @ScaledMetric(relativeTo: .title2) private var iconSize: CGFloat = 30

  private struct Icon: Identifiable {
    let id: String
    let label: String
  }
  private static let icons: [Icon] = [
    .init(id: "", label: "Default"), .init(id: "house", label: "Home"),
    .init(id: "calendar", label: "Calendar"), .init(id: "sun", label: "Weather"),
    .init(id: "music-notes", label: "Music"), .init(id: "image", label: "Photos"),
    .init(id: "cooking-pot", label: "Food"), .init(id: "check-square", label: "Tasks"),
    .init(id: "chart-bar", label: "Statistics"),
  ]
  private var icons: [Icon] {
    Self.icons.contains { $0.id == selection }
      ? Self.icons : Self.icons + [.init(id: selection, label: "Current icon")]
  }

  static func label(for value: String) -> String {
    String(
      localized: String.LocalizationValue(icons.first { $0.id == value }?.label ?? "Current icon"))
  }

  var body: some View {
    ScrollView {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 140 : 88))],
        spacing: 14
      ) {
        ForEach(icons) { icon in
          Button {
            selection = icon.id
            dismiss()
          } label: {
            VStack(spacing: 12) {
              PhosphorIcon(name: icon.id, size: iconSize)
              Text(LocalizedStringKey(icon.label)).font(.caption)
                .foregroundStyle(.primary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 86)
            .padding(12)
            .background(
              selection == icon.id
                ? Color.accentColor.opacity(0.12) : Color(.secondarySystemGroupedBackground),
              in: .rect(cornerRadius: 16)
            )
            .overlay(alignment: .topTrailing) {
              if selection == icon.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint).padding(6)
              }
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel(LocalizedStringKey(icon.label))
          .accessibilityValue(
            selection == icon.id ? String(localized: "Selected") : String(localized: "Not selected")
          )
          .accessibilityIdentifier("dashboard-icon-\(icon.id.isEmpty ? "default" : icon.id)")
        }
      }
      .padding()
    }
    .background(Color(.systemGroupedBackground))
    .navigationTitle("Icon").navigationBarTitleDisplayMode(.inline)
  }
}
