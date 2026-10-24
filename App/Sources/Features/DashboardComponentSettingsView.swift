import SwiftUI
import TesseraeKit

struct DashboardComponentSettingsView: View {
  let dashboardID: String
  let component: DashboardSettingComponent
  @Binding var draft: DashboardSettingsDraft
  let canEdit: Bool
  let fieldErrors: [String: String]
  let webURL: URL?
  @State private var query = ""

  private var matchingFields: [DashboardSettingInput] {
    component.fields.filter { field in
      query.isEmpty || field.label.localizedStandardContains(query)
        || field.name.localizedStandardContains(query)
        || field.help.localizedStandardContains(query)
    }
  }

  var body: some View {
    Form {
      if !component.available {
        Section {
          Label("Component unavailable", systemImage: "exclamationmark.triangle")
          Text("Check that this widget is installed and enabled on your server.")
        }
      }
      ForEach(DashboardSettingGroup.allCases) { group in
        let fields = matchingFields.filter { DashboardSettingGroup(field: $0) == group }
        if !fields.isEmpty {
          Section {
            ForEach(fields) { field in
              DashboardSettingsField(
                dashboardID: dashboardID, input: field, draft: $draft,
                component: true, canEdit: canEdit,
                error: field.fieldID.flatMap {
                  fieldErrors["component_values.\($0)"] ?? fieldErrors["reset_fields.\($0)"]
                }, webURL: webURL)
            }
          } header: {
            Text(group.title)
          }
        }
      }
      if matchingFields.isEmpty {
        Section {
          Text(
            LocalizedStringKey(
              query.isEmpty ? "No additional component settings" : "No matching settings.")
          )
          .foregroundStyle(.secondary)
        }
      }
      if component.fields.contains(where: { draft.hasChanges(for: $0, component: true) }) {
        Section {
          Text("Return to Dashboard Settings to save.").foregroundStyle(.secondary)
        }
      }
    }
    .scrollContentBackground(.hidden)
    .tesseraeScreenBackground()
    .searchable(
      text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Settings"
    )
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(component.label)
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("dashboard-component-settings")
  }
}

/// Presentation-only grouping; the server's field IDs and order within each group stay intact.
private enum DashboardSettingGroup: String, CaseIterable, Identifiable {
  case choices, text, numbers, switches, web
  var id: Self { self }
  var title: LocalizedStringKey {
    switch self {
    case .choices: "Selections"
    case .text: "Text"
    case .numbers: "Numbers"
    case .switches: "Switches"
    case .web: "Web settings"
    }
  }

  init(field: DashboardSettingInput) {
    guard field.isSupported else {
      self = .web
      return
    }
    switch field.type {
    case "select", "multiselect": self = .choices
    case "number", "integer": self = .numbers
    case "boolean", "switch": self = .switches
    default: self = .text
    }
  }
}

/// The first level shows summaries; only switches edit directly in the list.
struct DashboardSettingsField: View {
  let dashboardID: String
  let input: DashboardSettingInput
  @Binding var draft: DashboardSettingsDraft
  let component: Bool
  let canEdit: Bool
  let error: String?
  var webURL: URL? = nil
  @State private var choiceLabels: [DashboardSettingValue: String] = [:]
  @State private var showsDetails = false

  private var changed: Bool { draft.hasChanges(for: input, component: component) }
  private var currentValue: DashboardSettingValue? { draft.value(for: input, component: component) }
  private var mixed: Bool { input.mixed && !changed }
  private var isChoice: Bool { ["select", "multiselect"].contains(input.type) }
  private var isInlineSwitch: Bool {
    input.isSupported && !input.secret && !mixed && ["boolean", "switch"].contains(input.type)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if isInlineSwitch {
        HStack(spacing: 16) {
          Button {
            showsDetails = true
          } label: {
            HStack(spacing: 6) {
              Text(input.label).foregroundStyle(.primary)
              Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
          }
          .buttonStyle(.plain)
          .accessibilityHint("Opens setting details.")
          .accessibilityIdentifier("dashboard-field-detail-\(input.id)")
          Toggle(
            input.label,
            isOn: Binding(
              get: { currentValue == .bool(true) },
              set: { draft.setValue(.bool($0), for: input, component: component) }
            )
          )
          .labelsHidden().disabled(!canEdit)
        }
      } else {
        NavigationLink {
          detail
        } label: {
          LabeledContent {
            Text(summary).foregroundStyle(.secondary).lineLimit(2)
          } label: {
            Text(input.label)
          }
        }
        .accessibilityIdentifier(
          isChoice ? "dashboard-field-choices-\(input.id)" : "dashboard-field-detail-\(input.id)")
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("dashboard-input-\(input.id)")
    .navigationDestination(isPresented: $showsDetails) { detail }
  }

  private var detail: some View {
    DashboardSettingDetailView(
      dashboardID: dashboardID, input: input, draft: $draft, component: component,
      canEdit: canEdit, error: error, webURL: webURL, choiceLabels: $choiceLabels)
  }

  private var summary: String {
    if !input.isSupported { return String(localized: "Edit on the web") }
    if mixed { return String(localized: "Multiple different values") }
    if input.secret {
      if currentValue == .null { return String(localized: "Will be cleared when saved") }
      if draft.isReset(input, component: component) {
        return String(localized: "Will use the default when saved")
      }
      if changed { return String(localized: "Will be replaced when saved") }
      return input.configured
        ? String(localized: "Saved value") : String(localized: "Not configured")
    }
    guard let currentValue, currentValue != .null else { return String(localized: "None selected") }
    if !isChoice {
      return currentValue.settingText.isEmpty
        ? String(localized: "Not configured") : currentValue.settingSummary
    }
    let values: [DashboardSettingValue] =
      if case .array(let values) = currentValue { values } else { [currentValue] }
    if values.isEmpty { return String(localized: "None selected") }
    if input.choicesDynamic
      && values.contains(where: { item in
        choiceLabels[item] == nil && !input.choices.contains(where: { $0.value == item })
      })
    {
      return String(localized: "\(values.count) selected")
    }
    return values.map { value in
      choiceLabels[value] ?? input.choices.first { $0.value == value }?.label
        ?? value.settingSummary
    }.joined(separator: ", ")
  }
}

private struct DashboardSettingDetailView: View {
  let dashboardID: String
  let input: DashboardSettingInput
  @Binding var draft: DashboardSettingsDraft
  let component: Bool
  let canEdit: Bool
  let error: String?
  let webURL: URL?
  @Binding var choiceLabels: [DashboardSettingValue: String]
  @State private var numberText: String?

  private var changed: Bool { draft.hasChanges(for: input, component: component) }
  private var isReset: Bool { draft.isReset(input, component: component) }
  private var mixed: Bool { input.mixed && !changed }
  private var currentValue: DashboardSettingValue? { draft.value(for: input, component: component) }
  private var value: Binding<DashboardSettingValue?> {
    Binding(get: { currentValue }, set: { draft.setValue($0, for: input, component: component) })
  }
  private var text: Binding<String> {
    Binding(
      get: { numberText ?? currentValue?.settingText ?? "" },
      set: { new in
        if ["number", "integer"].contains(input.type) { numberText = new }
        value.wrappedValue = input.value(from: new)
      })
  }

  var body: some View {
    Group {
      if input.isSupported && !input.secret && !mixed
        && ["select", "multiselect"].contains(input.type)
      {
        DashboardSettingChoicesView(
          dashboardID: dashboardID, input: input, value: value, labels: $choiceLabels,
          schemaRevision: draft.original.schemaRevision, canEdit: canEdit
        ) {
          details
        }
      } else {
        Form {
          if input.isSupported {
            Section {
              if mixed {
                Text("Multiple different values").foregroundStyle(.secondary)
                Button("Set a shared value") { value.wrappedValue = initialSharedValue }
                  .disabled(!canEdit)
              } else {
                control.disabled(!canEdit)
              }
            }
          }
          details
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .scrollDismissesKeyboard(.interactively)
      }
    }
    .navigationTitle(input.label)
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("dashboard-setting-detail-\(input.id)")
  }

  @ViewBuilder private var details: some View {
    if let error { Section { Text(error).foregroundStyle(.red) } }
    Section("About this setting") {
      if !input.help.isEmpty { Text(input.help) }
      if !input.isSupported {
        Text(input.readonlyReason ?? String(localized: "This field requires the web editor."))
        if let webURL {
          Link(destination: webURL) { Label("Open in Tesserae", systemImage: "safari") }
        }
      }
      if input.required { LabeledContent("Required", value: String(localized: "Yes")) }
      if !input.secret, let defaultValue = input.defaultValue {
        LabeledContent("Default", value: defaultSummary(defaultValue))
      }
      if let minimum = input.min { LabeledContent("Minimum", value: minimum.formatted()) }
      if let maximum = input.max { LabeledContent("Maximum", value: maximum.formatted()) }
      if let step = input.step { LabeledContent("Step", value: step.formatted()) }
      if input.secret {
        Text(secretStatus).foregroundStyle(.secondary)
      } else if isReset {
        Text("Will use the default when saved").foregroundStyle(.secondary)
      } else if input.usingDefault && !changed {
        Text("Using default").foregroundStyle(.secondary)
      }
      Text("Return to Dashboard Settings to save.").foregroundStyle(.secondary)
    }
    if input.isSupported && (changed || input.resettable || input.canClear) {
      Section {
        if changed {
          Button("Keep saved value") {
            numberText = nil
            draft.restore(input, component: component)
          }.disabled(!canEdit)
        }
        if input.resettable {
          Button("Use widget default") {
            numberText = nil
            draft.reset(input, component: component)
          }.disabled(!canEdit || isReset || (input.usingDefault && !changed))
        }
        if input.canClear {
          Button("Clear saved value", role: .destructive) {
            numberText = nil
            value.wrappedValue = .null
          }.disabled(!canEdit)
        }
      }
    }
  }

  private func defaultSummary(_ value: DashboardSettingValue) -> String {
    if case .array(let values) = value {
      return values.isEmpty
        ? String(localized: "None selected") : values.map(defaultSummary).joined(separator: ", ")
    }
    return choiceLabels[value] ?? input.choices.first { $0.value == value }?.label
      ?? value.settingSummary
  }

  @ViewBuilder private var control: some View {
    if input.secret {
      SecureField(input.configured ? "Replace saved value" : "Not configured", text: text)
        .autocorrectionDisabled().textInputAutocapitalization(.never)
        .accessibilityLabel(input.label)
    } else {
      switch input.type {
      case "boolean", "switch":
        Toggle(
          input.label,
          isOn: Binding(
            get: { currentValue == .bool(true) }, set: { value.wrappedValue = .bool($0) }))
      case "number", "integer":
        TextField(input.label, text: text).keyboardType(.numbersAndPunctuation)
      case "url":
        TextField(input.label, text: text).keyboardType(.URL)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
      default:
        TextField(
          input.label, text: text,
          axis: ["textarea", "text"].contains(input.type) ? .vertical : .horizontal)
      }
    }
  }

  private var initialSharedValue: DashboardSettingValue {
    if let value = input.defaultValue, value != .null { return value }
    switch input.type {
    case "boolean", "switch": return .bool(false)
    case "number", "integer": return .number(input.min ?? 0)
    case "multiselect": return .array([])
    default: return .string("")
    }
  }

  private var secretStatus: String {
    if currentValue == .null { return String(localized: "Will be cleared when saved") }
    if isReset { return String(localized: "Will use the default when saved") }
    if changed { return String(localized: "Will be replaced when saved") }
    return input.configured
      ? String(localized: "Saved value will be kept") : String(localized: "Not configured")
  }
}

extension DashboardSettingValue {
  var settingSummary: String {
    switch self {
    case .null: String(localized: "None selected")
    case .bool(let value): String(localized: value ? "On" : "Off")
    case .array(let values): values.map(\.settingText).joined(separator: ", ")
    case .object: String(localized: "Saved value")
    default: settingText
    }
  }
}
