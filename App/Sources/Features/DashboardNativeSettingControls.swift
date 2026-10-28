import SwiftUI
import TesseraeKit
import UIKit

struct DashboardSliderSettingControl: View {
  let input: DashboardSettingInput
  @Binding var value: DashboardSettingValue?
  @State private var numberText: String?

  var body: some View {
    if let range = DashboardSettingSlider(input) {
      VStack(alignment: .leading, spacing: 12) {
        Slider(value: Binding(
          get: { range.displayValue(value) },
          set: { value = .number(range.snapped($0)); numberText = nil }
        ), in: range.minimum...range.maximum, step: range.step) {
          Text(input.label)
        }
        .accessibilityValue(valueLabel)
        .accessibilityIdentifier("dashboard-slider-\(input.id)")
        HStack {
          TextField(input.label, text: Binding(
            get: { numberText ?? value?.settingText ?? "" },
            set: { numberText = $0; value = input.value(from: $0) }
          ))
          .keyboardType(.numbersAndPunctuation)
          .accessibilityIdentifier("dashboard-number-\(input.id)")
          if let unit = input.unit, !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
      }
      .onChange(of: value) { _, newValue in
        if let numberText, input.value(from: numberText) != newValue { self.numberText = nil }
      }
    } else {
      TextField(input.label, text: Binding(
        get: { value?.settingText ?? "" }, set: { value = input.value(from: $0) }
      )).keyboardType(.numbersAndPunctuation)
    }
  }

  private var valueLabel: String {
    [value?.settingText ?? "", input.unit ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
  }
}

struct DashboardColorSettingControl: View {
  let input: DashboardSettingInput
  @Binding var value: DashboardSettingValue?

  var body: some View {
    HStack {
      Text(input.label).frame(maxWidth: .infinity, alignment: .leading)
      ColorPicker(selection: Binding(
        get: {
          let rgba = DashboardSettingColor(css: value?.settingText ?? "")
          return Color(.sRGB, red: rgba?.red ?? 1, green: rgba?.green ?? 1,
            blue: rgba?.blue ?? 1, opacity: rgba?.opacity ?? 1)
        },
        set: { color in
          var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
          guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
          value = .string(DashboardSettingColor(red: Double(red), green: Double(green),
            blue: Double(blue), opacity: Double(alpha)).css)
        }
      ), supportsOpacity: false) { EmptyView() }
      .labelsHidden()
      .scaleEffect(44.0 / 28.0)
      .frame(width: 44, height: 44)
      .accessibilityLabel(input.label)
      .accessibilityValue(value?.settingText ?? "")
      .accessibilityIdentifier("dashboard-color-\(input.id)")
    }
    TextField("Color value", text: Binding(
      get: { value?.settingText ?? "" }, set: { value = input.value(from: $0) }
    ))
    .textInputAutocapitalization(.never).autocorrectionDisabled()
    .accessibilityIdentifier("dashboard-color-value-\(input.id)")
    Text("Use a six-digit hex color, such as #336699.")
      .font(.footnote).foregroundStyle(.secondary)
  }
}

struct DashboardLocationSettingView<Details: View>: View {
  @Environment(AppModel.self) private var model
  let dashboardID: String
  let input: DashboardSettingInput
  @Binding var value: DashboardSettingValue?
  let schemaRevision: String?
  let canEdit: Bool
  @ViewBuilder let details: () -> Details
  @State private var query = ""
  @State private var results: [DashboardSettingChoice] = []
  @State private var isLoading = false
  @State private var error: String?
  @State private var requestID = UUID()

  var body: some View {
    Form {
      if let place = DashboardSettingLocation(value) {
        Section("Selected") {
          Text(place.summary).accessibilityIdentifier("dashboard-location-selected")
          LabeledContent("Latitude", value: place.latitude.formatted())
          LabeledContent("Longitude", value: place.longitude.formatted())
          if !place.timezone.isEmpty { LabeledContent("Time Zone", value: place.timezone) }
        }
      } else if let value, value != .null, value != .object([:]), value != .string("") {
        Section("Selected") { Text(value.settingText.isEmpty ? String(localized: "Saved location") : value.settingText) }
      }
      Section("Location") {
        TextField("Search places", text: $query)
          .textInputAutocapitalization(.words).autocorrectionDisabled()
          .disabled(!canEdit)
          .accessibilityIdentifier("dashboard-location-query")
        if isLoading { ProgressView().frame(maxWidth: .infinity) }
        ForEach(results, id: \.value) { result in
          Button {
            value = result.value
            query = ""
            results = []
          } label: {
            Label(result.label, systemImage: "mappin.and.ellipse")
              .foregroundStyle(.primary).frame(minHeight: 44)
          }
          .disabled(!canEdit)
        }
        if let error {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await search() } }.disabled(!canEdit || isLoading)
        } else if !isLoading && query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 && results.isEmpty {
          Text("No matching places.").foregroundStyle(.secondary)
        }
        NavigationLink {
          DashboardCoordinateSettingView(value: $value, canEdit: canEdit)
        } label: {
          Label("Enter Coordinates", systemImage: "location")
        }
        .accessibilityIdentifier("dashboard-location-coordinates")
      }
      details()
    }
    .scrollContentBackground(.hidden)
    .tesseraeScreenBackground()
    .scrollDismissesKeyboard(.interactively)
    .navigationTitle(input.label)
    .navigationBarTitleDisplayMode(.inline)
    .task(id: query) {
      do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() }
      catch { return }
      await search()
    }
  }

  @MainActor private func search() async {
    let request = UUID()
    requestID = request
    let requestedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    results = []
    error = nil
    guard requestedQuery.count >= 2, canEdit, let fieldID = input.fieldID else {
      isLoading = false
      return
    }
    isLoading = true
    defer { if requestID == request { isLoading = false } }
    do {
      let page = try await model.fetchDashboardSettingChoices(dashboardID, fieldID: fieldID,
        query: requestedQuery, offset: 0, schemaRevision: schemaRevision)
      try Task.checkCancellation()
      guard requestID == request,
        query.trimmingCharacters(in: .whitespacesAndNewlines) == requestedQuery else { return }
      guard page.status == "ready" else {
        error = String(localized: "Place search is unavailable. Try again or enter coordinates.")
        return
      }
      var seen = Set<DashboardSettingValue>()
      results = page.choices.filter { DashboardSettingLocation($0.value) != nil && seen.insert($0.value).inserted }
    } catch is CancellationError {
    } catch {
      guard requestID == request else { return }
      self.error = String(localized: "Place search is unavailable. Try again or enter coordinates.")
    }
  }
}

private struct DashboardCoordinateSettingView: View {
  @Environment(\.dismiss) private var dismiss
  @Binding var value: DashboardSettingValue?
  let canEdit: Bool
  @State private var latitude: String
  @State private var longitude: String
  @State private var name: String
  @State private var timezone: String

  init(value: Binding<DashboardSettingValue?>, canEdit: Bool) {
    _value = value
    self.canEdit = canEdit
    let place = DashboardSettingLocation(value.wrappedValue)
    latitude = place.map { String($0.latitude) } ?? ""
    longitude = place.map { String($0.longitude) } ?? ""
    name = place?.name ?? ""
    timezone = place?.timezone ?? ""
  }

  private var updatedValue: DashboardSettingValue? {
    guard let latitude = Double(latitude), let longitude = Double(longitude) else { return nil }
    return DashboardSettingLocation.coordinates(latitude: latitude, longitude: longitude,
      name: name, timezone: timezone.trimmingCharacters(in: .whitespacesAndNewlines), preserving: value)
  }

  var body: some View {
    Form {
      Section {
        LabeledContent("Latitude") {
          TextField("Latitude", text: $latitude).keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("dashboard-location-latitude")
        }
        LabeledContent("Longitude") {
          TextField("Longitude", text: $longitude).keyboardType(.numbersAndPunctuation)
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("dashboard-location-longitude")
        }
        LabeledContent("Place name") {
          TextField("Place name", text: $name).multilineTextAlignment(.trailing)
        }
        LabeledContent("Time Zone") {
          TextField("Time Zone", text: $timezone).textInputAutocapitalization(.never).autocorrectionDisabled()
            .multilineTextAlignment(.trailing)
            .accessibilityIdentifier("dashboard-location-timezone")
        }
      } footer: {
        if updatedValue == nil {
          Text("Enter a latitude from −90 to 90, a longitude from −180 to 180, and a valid time zone or leave it empty.")
        }
      }
      .disabled(!canEdit)
    }
    .scrollContentBackground(.hidden)
    .tesseraeScreenBackground()
    .navigationTitle("Coordinates")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      TesseraeToolbarActions {
        Button("Done", systemImage: "checkmark") {
          if let updatedValue { value = updatedValue; dismiss() }
        }
        .disabled(!canEdit || updatedValue == nil)
        .accessibilityIdentifier("dashboard-location-done")
      }
    }
  }
}
