import Foundation

/// JSON values are shared with Lineups so arbitrary field names and choice types round-trip.
public typealias DashboardSettingValue = LineupJSONValue

public struct DashboardSettingChoice: Codable, Hashable, Sendable {
  public let value: DashboardSettingValue
  public let label: String

  public init(value: DashboardSettingValue, label: String) {
    self.value = value
    self.label = label
  }
}

/// Shared presentation metadata for declared Dashboard inputs and discovered component fields.
public struct DashboardSettingInput: Codable, Hashable, Sendable, Identifiable {
  public let name: String
  public let label: String
  public let type: String
  public let required: Bool
  public let help: String
  public let choices: [DashboardSettingChoice]
  public let secret: Bool
  public var editable: Bool
  public var configured: Bool
  public var value: DashboardSettingValue?
  public let fieldID: String?
  public let defaultValue: DashboardSettingValue?
  public var hasOverride: Bool
  public var valueState: String
  public var usingDefault: Bool { !hasOverride && defaultValue != nil }
  public var mixed: Bool { valueState == "mixed" }
  public let canClear: Bool
  public let resettable: Bool
  public let choicesDynamic: Bool
  public let readonlyReason: String?
  public let min: Double?
  public let max: Double?
  public let step: Double?
  public var id: String { fieldID ?? name }

  public init(
    name: String, label: String, type: String, required: Bool, help: String,
    choices: [DashboardSettingChoice], secret: Bool, editable: Bool, configured: Bool,
    value: DashboardSettingValue?, fieldID: String? = nil,
    defaultValue: DashboardSettingValue? = nil, usingDefault: Bool = false,
    mixed: Bool = false, resettable: Bool = false, choicesDynamic: Bool = false,
    readonlyReason: String? = nil, min: Double? = nil, max: Double? = nil, step: Double? = nil,
    canClear: Bool? = nil, hasOverride: Bool? = nil, valueState: String? = nil
  ) {
    self.name = name
    self.label = label
    self.type = type
    self.required = required
    self.help = help
    self.choices = secret ? [] : choices
    self.secret = secret
    self.editable = editable
    self.configured = configured
    self.value = secret ? nil : value
    self.fieldID = fieldID
    self.defaultValue = secret ? nil : defaultValue
    self.hasOverride = hasOverride ?? (usingDefault ? false : configured)
    self.valueState = valueState ?? (mixed ? "mixed" : (value == nil ? "unset" : "uniform"))
    self.canClear = canClear ?? !required
    self.resettable = resettable
    self.choicesDynamic = choicesDynamic
    self.readonlyReason = readonlyReason
    self.min = min
    self.max = max
    self.step = step
  }

  public var isSupported: Bool {
    editable
      && [
        "string", "text", "textarea", "url", "password", "color", "number", "integer",
        "boolean", "switch", "select", "multiselect",
      ].contains(type)
  }
  /// Empty secret text means keep; optional numeric text can explicitly clear.
  public func value(from text: String) -> DashboardSettingValue? {
    if secret && text.isEmpty { return nil }
    if ["number", "integer"].contains(type) {
      if text.isEmpty && !required { return .null }
      if let number = Double(text), number.isFinite { return .number(number) }
    }
    return .string(text)
  }

  enum CodingKeys: String, CodingKey {
    case name, label, type, required, help, choices, secret, editable, configured, value
    case fieldID = "fieldId"
    case defaultValue = "default"
    case resettable = "canReset"
    case choicesDynamic = "dynamicChoices"
    case min = "minimum"
    case max = "maximum"
    case valueState, hasOverride, canClear, readonlyReason, step
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let fieldID = try values.decodeIfPresent(String.self, forKey: .fieldID)
    let name = try values.decodeIfPresent(String.self, forKey: .name) ?? fieldID ?? ""
    self.init(
      name: name,
      label: try values.decodeIfPresent(String.self, forKey: .label) ?? name,
      type: try values.decodeIfPresent(String.self, forKey: .type) ?? "unknown",
      required: try values.decodeIfPresent(Bool.self, forKey: .required) ?? false,
      help: try values.decodeIfPresent(String.self, forKey: .help) ?? "",
      choices: try values.decodeIfPresent([DashboardSettingChoice].self, forKey: .choices) ?? [],
      secret: try values.decodeIfPresent(Bool.self, forKey: .secret) ?? false,
      editable: try values.decodeIfPresent(Bool.self, forKey: .editable) ?? false,
      configured: try values.decodeIfPresent(Bool.self, forKey: .configured) ?? false,
      value: values.contains(.value) ? try values.decode(DashboardSettingValue.self, forKey: .value) : nil,
      fieldID: fieldID,
      defaultValue: values.contains(.defaultValue) ? try values.decode(DashboardSettingValue.self, forKey: .defaultValue) : nil,
      resettable: try values.decodeIfPresent(Bool.self, forKey: .resettable) ?? false,
      choicesDynamic: try values.decodeIfPresent(Bool.self, forKey: .choicesDynamic) ?? false,
      readonlyReason: try values.decodeIfPresent(String.self, forKey: .readonlyReason),
      min: try values.decodeIfPresent(Double.self, forKey: .min),
      max: try values.decodeIfPresent(Double.self, forKey: .max),
      step: try values.decodeIfPresent(Double.self, forKey: .step),
      canClear: try values.decodeIfPresent(Bool.self, forKey: .canClear),
      hasOverride: try values.decodeIfPresent(Bool.self, forKey: .hasOverride),
      valueState: try values.decodeIfPresent(String.self, forKey: .valueState))
  }
}

public struct DashboardSettingComponent: Codable, Hashable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let kind: String
  public let widget: String
  public var fields: [DashboardSettingInput]
  public let available: Bool
  public let fragment: String?
  public let sourceName: String?
  public var status: String { available ? "available" : "unavailable" }

  public init(id: String, label: String, kind: String, widget: String,
              fields: [DashboardSettingInput], available: Bool = true,
              fragment: String? = nil, sourceName: String? = nil) {
    self.id = id
    self.label = label
    self.kind = kind
    self.widget = widget
    self.fields = fields
    self.available = available
    self.fragment = fragment
    self.sourceName = sourceName
  }

  enum CodingKeys: String, CodingKey {
    case id, label, kind, fields, available, fragment, sourceName
    case widget = "widgetId"
  }
}

public struct DashboardSettingsCoverage: Codable, Hashable, Sendable {
  public let status: String
  public let editableFields: Int
  public let readonlyFields: Int
  public let unavailableComponents: Int

  public init(status: String, editableFields: Int, readonlyFields: Int, unavailableComponents: Int) {
    self.status = status
    self.editableFields = editableFields
    self.readonlyFields = readonlyFields
    self.unavailableComponents = unavailableComponents
  }
}

public struct DashboardSettingChoices: Codable, Hashable, Sendable {
  public let choices: [DashboardSettingChoice]
  public let total: Int
  public let offset: Int
  public let limit: Int
  public let hasMore: Bool
  public let fieldID: String
  public let schemaRevision: String?
  public let status: String
  public let message: String?
  public var nextOffset: Int? { hasMore && limit > 0 ? offset + limit : nil }

  public init(choices: [DashboardSettingChoice], total: Int, offset: Int, limit: Int, hasMore: Bool,
              fieldID: String = "", schemaRevision: String? = nil,
              status: String = "ready", message: String? = nil) {
    self.choices = choices
    self.total = total
    self.offset = offset
    self.limit = limit
    self.hasMore = hasMore
    self.fieldID = fieldID
    self.schemaRevision = schemaRevision
    self.status = status
    self.message = message
  }

  enum CodingKeys: String, CodingKey {
    case choices, total, offset, limit, hasMore, schemaRevision, status, message
    case fieldID = "fieldId"
  }
}

public struct DashboardSettings: Codable, Hashable, Sendable {
  public let kind: DashboardKind
  public let dashboardID: String
  public let revision: String
  public let canEdit: Bool
  public let settings: [String: DashboardSettingValue]
  public let options: [String: [DashboardSettingChoice]]
  public let inputs: [DashboardSettingInput]
  public let webURL: String
  public let schemaRevision: String?
  public let components: [DashboardSettingComponent]
  public let coverage: DashboardSettingsCoverage?

  public init(kind: DashboardKind, dashboardID: String, revision: String, canEdit: Bool,
              settings: [String: DashboardSettingValue], options: [String: [DashboardSettingChoice]],
              inputs: [DashboardSettingInput], webURL: String, schemaRevision: String? = nil,
              components: [DashboardSettingComponent] = [], coverage: DashboardSettingsCoverage? = nil) {
    self.kind = kind
    self.dashboardID = dashboardID
    self.revision = revision
    self.canEdit = canEdit
    self.settings = settings
    self.options = options
    self.inputs = inputs
    self.webURL = webURL
    self.schemaRevision = schemaRevision
    self.components = components
    self.coverage = coverage
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      kind: try values.decode(DashboardKind.self, forKey: .kind),
      dashboardID: try values.decode(String.self, forKey: .dashboardID),
      revision: try values.decode(String.self, forKey: .revision),
      canEdit: try values.decode(Bool.self, forKey: .canEdit),
      settings: try values.decode([String: DashboardSettingValue].self, forKey: .settings),
      options: try values.decode([String: [DashboardSettingChoice]].self, forKey: .options),
      inputs: try values.decode([DashboardSettingInput].self, forKey: .inputs),
      webURL: try values.decode(String.self, forKey: .webURL),
      schemaRevision: try values.decodeIfPresent(String.self, forKey: .schemaRevision),
      components: try values.decodeIfPresent([DashboardSettingComponent].self, forKey: .components) ?? [],
      coverage: try values.decodeIfPresent(DashboardSettingsCoverage.self, forKey: .coverage))
  }

  /// Malformed/older servers may send duplicate names. Show ambiguous controls
  /// read-only and never let a non-secret alias reveal a secret value.
  public var displayInputs: [DashboardSettingInput] {
    let groups = Dictionary(grouping: inputs, by: \.name)
    var seen: Set<String> = []
    return inputs.compactMap { input in
      guard seen.insert(input.name).inserted else { return nil }
      let matching = groups[input.name] ?? []
      guard matching.count > 1 else { return input }
      let secret = matching.contains { $0.secret }
      return DashboardSettingInput(
        name: input.name, label: input.label, type: input.type,
        required: input.required, help: input.help, choices: secret ? [] : input.choices,
        secret: secret, editable: false, configured: matching.contains { $0.configured },
        value: secret ? nil : input.value)
    }
  }

  enum CodingKeys: String, CodingKey {
    case dashboardID = "dashboardId"
    case kind, revision, canEdit, settings, options, inputs, schemaRevision, components, coverage
    case webURL = "webUrl"
  }
}

public struct DashboardSettingsPatch: Codable, Hashable, Sendable {
  public let revision: String
  public let settings: [String: DashboardSettingValue]
  public let inputs: [String: DashboardSettingValue]
  public let schemaRevision: String?
  public let componentValues: [String: DashboardSettingValue]
  public let resetFields: [String]

  public init(
    revision: String, settings: [String: DashboardSettingValue],
    inputs: [String: DashboardSettingValue], schemaRevision: String? = nil,
    componentValues: [String: DashboardSettingValue] = [:], resetFields: [String] = []
  ) {
    self.revision = revision
    self.settings = settings
    self.inputs = inputs
    self.schemaRevision = schemaRevision
    self.componentValues = componentValues
    self.resetFields = resetFields
  }
  public var isEmpty: Bool {
    settings.isEmpty && inputs.isEmpty && componentValues.isEmpty && resetFields.isEmpty
  }

  enum CodingKeys: String, CodingKey {
    case revision, settings, inputs, schemaRevision, componentValues, resetFields
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      revision: try values.decode(String.self, forKey: .revision),
      settings: try values.decodeIfPresent([String: DashboardSettingValue].self, forKey: .settings) ?? [:],
      inputs: try values.decodeIfPresent([String: DashboardSettingValue].self, forKey: .inputs) ?? [:],
      schemaRevision: try values.decodeIfPresent(String.self, forKey: .schemaRevision),
      componentValues: try values.decodeIfPresent([String: DashboardSettingValue].self, forKey: .componentValues) ?? [:],
      resetFields: try values.decodeIfPresent([String].self, forKey: .resetFields) ?? [])
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(revision, forKey: .revision)
    try values.encode(settings, forKey: .settings)
    try values.encode(inputs, forKey: .inputs)
    try values.encodeIfPresent(schemaRevision, forKey: .schemaRevision)
    // Older servers reject unknown PATCH keys even when their dictionaries are empty.
    if !componentValues.isEmpty { try values.encode(componentValues, forKey: .componentValues) }
    if !resetFields.isEmpty { try values.encode(resetFields, forKey: .resetFields) }
  }
}

/// Keep one draft while navigating component forms, and submit only explicit changes.
public struct DashboardSettingsDraft: Equatable, Sendable {
  public let original: DashboardSettings
  public var settings: [String: DashboardSettingValue]
  public var inputs: [String: DashboardSettingValue]
  public var componentValues: [String: DashboardSettingValue]
  public private(set) var resetFields: Set<String> = []

  public init(_ original: DashboardSettings) {
    self.original = original
    settings = original.settings
    inputs = Self.baseline(original.displayInputs, component: false)
    componentValues = Self.baseline(original.components.flatMap(\.fields), component: true)
  }

  private static func baseline(_ fields: [DashboardSettingInput], component: Bool) -> [String: DashboardSettingValue] {
    fields.reduce(into: [:]) { result, field in
      guard !field.secret, !field.mixed, let value = field.value ?? field.defaultValue else { return }
      result[component ? field.id : field.name] = value
    }
  }

  public func value(for field: DashboardSettingInput, component: Bool = false) -> DashboardSettingValue? {
    if isReset(field, component: component) { return field.defaultValue }
    return component ? componentValues[field.id] : inputs[field.name]
  }

  public mutating func setValue(_ value: DashboardSettingValue?, for field: DashboardSettingInput, component: Bool = false) {
    if let fieldID = field.fieldID { resetFields.remove(fieldID) }
    if component { componentValues[field.id] = value } else { inputs[field.name] = value }
  }

  public mutating func reset(_ field: DashboardSettingInput, component: Bool = false) {
    guard field.resettable, let fieldID = field.fieldID else { return }
    restore(field, component: component)
    if field.hasOverride || field.mixed { resetFields.insert(fieldID) }
  }

  public mutating func restore(_ field: DashboardSettingInput, component: Bool = false) {
    if let fieldID = field.fieldID { resetFields.remove(fieldID) }
    let value = Self.baseline([field], component: component)[component ? field.id : field.name]
    if component { componentValues[field.id] = value } else { inputs[field.name] = value }
  }

  public func isReset(_ field: DashboardSettingInput, component: Bool = false) -> Bool {
    field.fieldID.map(resetFields.contains) ?? false
  }

  public func hasChanges(for field: DashboardSettingInput, component: Bool = false) -> Bool {
    if isReset(field, component: component) { return true }
    return component ? patch.componentValues[field.id] != nil : patch.inputs[field.name] != nil
  }

  public var patch: DashboardSettingsPatch {
    let originalInputs = Self.baseline(original.displayInputs, component: false)
    let originalComponents = Self.baseline(original.components.flatMap(\.fields), component: true)
    let resetInputNames = Set(original.displayInputs.filter { isReset($0) }.map(\.name))
    return DashboardSettingsPatch(
      revision: original.revision,
      settings: settings.filter { original.settings[$0.key] != $0.value },
      inputs: inputs.filter { !resetInputNames.contains($0.key) && originalInputs[$0.key] != $0.value },
      schemaRevision: original.schemaRevision,
      componentValues: componentValues.filter { !resetFields.contains($0.key) && originalComponents[$0.key] != $0.value },
      resetFields: resetFields.sorted())
  }
  public var hasChanges: Bool { !patch.isEmpty }
}

extension LineupJSONValue {
  public var settingText: String {
    switch self {
    case .string(let value): value
    case .number(let value):
      String(value).hasSuffix(".0") ? String(String(value).dropLast(2)) : String(value)
    case .bool(let value): value ? "true" : "false"
    default: ""
    }
  }
}

public struct DashboardSettingsValidationError: Error, LocalizedError, Sendable {
  public let message: String
  public let fields: [String: String]
  public var errorDescription: String? { message }
}
