import SwiftUI
import TesseraeKit

struct DashboardComponentSettingsView: View {
  let dashboardID: String
  let component: DashboardSettingComponent
  @Binding var draft: DashboardSettingsDraft
  let canEdit: Bool
  let fieldErrors: [String: String]
  let webURL: URL?

  var body: some View {
    Form {
      if !component.available {
        Section {
          Label("Component unavailable", systemImage: "exclamationmark.triangle")
          Text("Check that this widget is installed and enabled on your server.")
        }
      }
      Section {
        ForEach(component.fields.filter(\.isSupported)) { field in
          fieldRow(field)
        }
        if component.available && component.fields.isEmpty {
          Text("No additional component settings").foregroundStyle(.secondary)
        }
      } footer: {
        if component.fields.contains(where: { draft.hasChanges(for: $0, component: true) }) {
          Text("Return to Dashboard Settings to save.")
        }
      }
      if component.fields.contains(where: { !$0.isSupported }) {
        Section {
          DisclosureGroup("Web settings") {
            ForEach(component.fields.filter { !$0.isSupported }) { field in
              fieldRow(field)
            }
            if let webURL {
              Link(destination: webURL) { Label("Open in Tesserae", systemImage: "safari") }
            }
          }
        }
      }
    }
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(component.label)
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("dashboard-component-settings")
  }

  private func fieldRow(_ field: DashboardSettingInput) -> some View {
    DashboardSettingsField(
      dashboardID: dashboardID, input: field, draft: $draft,
      component: true, canEdit: canEdit,
      error: field.fieldID.flatMap {
        fieldErrors["component_values.\($0)"] ?? fieldErrors["reset_fields.\($0)"]
      })
  }
}

/// Both declared inputs and discovered widget options edit the same parent draft.
struct DashboardSettingsField: View {
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  let dashboardID: String
  let input: DashboardSettingInput
  @Binding var draft: DashboardSettingsDraft
  let component: Bool
  let canEdit: Bool
  let error: String?
  @State private var numberText: String?
  @State private var choiceLabels: [DashboardSettingValue: String] = [:]
  @State private var showsDetails = false

  private var changed: Bool { draft.hasChanges(for: input, component: component) }
  private var isReset: Bool { draft.isReset(input, component: component) }
  private var currentValue: DashboardSettingValue? { draft.value(for: input, component: component) }
  private var value: Binding<DashboardSettingValue?> {
    Binding(
      get: { currentValue },
      set: {
        draft.setValue($0, for: input, component: component)
      })
  }
  private var mixed: Bool { input.mixed && !changed }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(alignment: .center, spacing: 8) {
        Group {
          if !input.isSupported {
            LabeledContent(input.label, value: String(localized: "Edit on the web"))
          } else if mixed {
            VStack(alignment: .leading, spacing: 4) {
              Text(input.label)
              Button("Set a shared value") { value.wrappedValue = initialSharedValue }
                .disabled(!canEdit)
            }
          } else if input.secret {
            secretControl
          } else {
            control
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        valueActions
      }
      if mixed {
        Text("Multiple different values").font(.caption).foregroundStyle(.secondary)
      } else if isReset {
        Text("Will use the default when saved").font(.caption).foregroundStyle(.secondary)
      }
      if let error { Text(error).font(.caption).foregroundStyle(.red) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("dashboard-input-\(input.id)")
    .sheet(isPresented: $showsDetails) {
      NavigationStack {
        Form {
          if !input.help.isEmpty { Section { Text(input.help) } }
          Section {
            if input.required { LabeledContent("Required", value: String(localized: "Yes")) }
            if !input.secret, let defaultValue = input.defaultValue {
              LabeledContent("Default", value: defaultValue.settingSummary)
            }
            if !input.secret && input.usingDefault && !changed { Text("Using default") }
            if let minimum = input.min { LabeledContent("Minimum", value: minimum.formatted()) }
            if let maximum = input.max { LabeledContent("Maximum", value: maximum.formatted()) }
            if !input.isSupported { Text("This field requires the web editor.") }
          }
        }
        .navigationTitle(input.label).navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showsDetails = false }
          }
        }
      }
      .presentationDetents([.medium, .large])
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

  private var secretControl: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(input.label)
      SecureField(input.configured ? "Replace saved value" : "Not configured", text: text)
        .autocorrectionDisabled().textInputAutocapitalization(.never)
        .disabled(!canEdit)
      if changed { Text(secretStatus).font(.caption).foregroundStyle(.secondary) }
    }
  }

  private var secretStatus: String {
    if currentValue == .null { return String(localized: "Will be cleared when saved") }
    if isReset { return String(localized: "Will use the default when saved") }
    if changed { return String(localized: "Will be replaced when saved") }
    return input.configured
      ? String(localized: "Saved value will be kept") : String(localized: "Not configured")
  }

  private var hasDetails: Bool {
    !input.help.isEmpty || input.required || input.min != nil || input.max != nil
      || (!input.secret && input.defaultValue != nil) || !input.isSupported
  }

  @ViewBuilder private var valueActions: some View {
    if hasDetails || (input.isSupported && (changed || input.canClear || input.resettable)) {
      Menu {
        if hasDetails {
          Button("About this setting", systemImage: "info.circle") { showsDetails = true }
        }
        if input.isSupported {
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
      } label: {
        Image(systemName: "ellipsis.circle").foregroundStyle(.secondary)
          .frame(minWidth: 44, minHeight: 44)
      }
      .accessibilityLabel("Options for \(input.label)")
      .accessibilityIdentifier("dashboard-field-actions-\(input.id)")
    }
  }

  private var text: Binding<String> {
    Binding(
      get: { numberText ?? currentValue?.settingText ?? "" },
      set: { new in
        if ["number", "integer"].contains(input.type) { numberText = new }
        value.wrappedValue = input.value(from: new)
      })
  }

  @ViewBuilder private var control: some View {
    switch input.type {
    case "boolean", "switch":
      Toggle(
        input.label,
        isOn: Binding(
          get: { currentValue == .bool(true) }, set: { value.wrappedValue = .bool($0) })
      )
      .disabled(!canEdit)
    case "select", "multiselect":
      NavigationLink {
        DashboardSettingChoicesView(
          dashboardID: dashboardID, input: input, value: value, labels: $choiceLabels,
          schemaRevision: draft.original.schemaRevision, canEdit: canEdit)
      } label: {
        VStack(alignment: .leading, spacing: 4) {
          Text(input.label)
          Text(selectionSummary).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      .accessibilityIdentifier("dashboard-field-choices-\(input.id)")
    case "number", "integer":
      textControl.keyboardType(.numbersAndPunctuation).disabled(!canEdit)
    case "url":
      textControl.keyboardType(.URL).textInputAutocapitalization(.never)
        .autocorrectionDisabled().disabled(!canEdit)
    default:
      textControl.disabled(!canEdit)
    }
  }

  @ViewBuilder private var textControl: some View {
    if dynamicTypeSize.isAccessibilitySize || ["textarea", "text", "url"].contains(input.type) {
      VStack(alignment: .leading, spacing: 4) {
        Text(input.label)
        TextField(
          input.label, text: text,
          axis: ["textarea", "text"].contains(input.type) ? .vertical : .horizontal)
      }
    } else {
      LabeledContent {
        TextField(input.label, text: text).multilineTextAlignment(.trailing)
          .frame(minWidth: 60)
      } label: {
        Text(input.label).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var selectionSummary: String {
    guard let currentValue, currentValue != .null else { return String(localized: "None selected") }
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

extension DashboardSettingValue {
  var settingSummary: String {
    switch self {
    case .null: String(localized: "None selected")
    case .array(let values): values.map(\.settingText).joined(separator: ", ")
    case .object: String(localized: "Saved value")
    default: settingText
    }
  }
}
