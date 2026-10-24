import SwiftUI
import TesseraeKit

struct DashboardSettingChoicesView<Details: View>: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Environment(\.dismiss) private var dismiss
  let dashboardID: String
  let input: DashboardSettingInput
  @Binding var value: DashboardSettingValue?
  @Binding var labels: [DashboardSettingValue: String]
  let schemaRevision: String?
  let canEdit: Bool
  @ViewBuilder let details: () -> Details
  @State private var query = ""
  @State private var choices: [DashboardSettingChoice] = []
  @State private var nextOffset: Int?
  @State private var isLoading = false
  @State private var error: String?
  @State private var requestID = UUID()

  private var multiple: Bool { input.type == "multiselect" }
  private var selected: [DashboardSettingValue] {
    guard let value, value != .null else { return [] }
    let values: [DashboardSettingValue] =
      if case .array(let items) = value { items } else { [value] }
    var seen = Set<DashboardSettingValue>()
    return values.filter { seen.insert($0).inserted }
  }

  var body: some View {
    List {
      if !selected.isEmpty {
        Section {
          ForEach(selected, id: \.self) { item in
            selectedRow(item)
          }
        } header: {
          Text(LocalizedStringKey(multiple ? "Priority" : "Selected"))
        } footer: {
          if multiple && selected.count > 1 { Text("First is preferred.") }
        }
      }
      Section("Available Choices") {
        ForEach(choices.filter { !selected.contains($0.value) }, id: \.value) { choice in
          Button {
            select(choice.value)
          } label: {
            HStack {
              Text(choice.label).foregroundStyle(.primary)
              Spacer()
              Image(systemName: "plus.circle").foregroundStyle(.tint)
            }
          }
          .disabled(!canEdit)
          .accessibilityValue(
            selected.contains(choice.value)
              ? String(localized: "Selected") : String(localized: "Not selected")
          )
          .accessibilityIdentifier("dashboard-choice-\(choice.value.settingText)")
        }
        if isLoading { ProgressView().frame(maxWidth: .infinity) }
        if let error {
          Text(error).foregroundStyle(.red)
          Button("Retry") { Task { await load(offset: 0) } }
        } else if !isLoading && nextOffset == nil
          && choices.allSatisfy({ selected.contains($0.value) })
        {
          Text(
            LocalizedStringKey(
              choices.isEmpty
                ? (query.isEmpty ? "No choices are available." : "No matching choices.")
                : "All choices selected")
          )
          .foregroundStyle(.secondary)
        }
        if let nextOffset, !isLoading, error == nil {
          Button("Load More") { Task { await load(offset: nextOffset) } }
            .accessibilityIdentifier("dashboard-choices-more")
        }
      }
      details()
    }
    .scrollContentBackground(.hidden)
    .tesseraeScreenBackground()
    .accessibilityIdentifier("dashboard-setting-choices")
    .navigationTitle(input.label)
    .navigationBarTitleDisplayMode(.inline)
    .searchable(
      text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Choices"
    )
    .searchPresentationToolbarBehavior(.avoidHidingContent)
    .toolbar {
      TesseraeToolbarActions {
        Button {
          Task { await load(offset: 0) }
        } label: {
          Label("Refresh Choices", systemImage: "arrow.clockwise")
        }
        .disabled(isLoading)
        .accessibilityIdentifier("dashboard-choices-refresh")
        Button("Done", systemImage: "checkmark") { dismiss() }
          .accessibilityIdentifier("dashboard-choices-done")
      }
    }
    .task(id: query) {
      // SwiftUI cancels this task when the search changes or this page closes.
      if !query.isEmpty {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
      }
      await load(offset: 0)
    }
  }

  private func label(for item: DashboardSettingValue) -> String {
    labels[item] ?? input.choices.first { $0.value == item }?.label ?? item.settingSummary
  }

  private func selectedRow(_ item: DashboardSettingValue) -> some View {
    Group {
      if dynamicTypeSize.isAccessibilitySize {
        VStack(alignment: .leading, spacing: 12) {
          Text(label(for: item)).frame(maxWidth: .infinity, alignment: .leading)
          HStack(spacing: 12) {
            selectionActions(item)
            Spacer(minLength: 0)
          }
        }
      } else {
        HStack(spacing: 12) {
          Text(label(for: item)).frame(maxWidth: .infinity, alignment: .leading)
          selectionActions(item)
        }
      }
    }
    .buttonStyle(.borderless)
  }

  @ViewBuilder private func selectionActions(_ item: DashboardSettingValue) -> some View {
    if multiple {
      Button {
        move(item, by: -1)
      } label: {
        Image(systemName: "arrow.up").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(!canEdit || selected.first == item)
      .accessibilityLabel("Move \(label(for: item)) up")
      .accessibilityIdentifier("dashboard-choice-up-\(item.settingText)")
      Button {
        move(item, by: 1)
      } label: {
        Image(systemName: "arrow.down").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(!canEdit || selected.last == item)
      .accessibilityLabel("Move \(label(for: item)) down")
      .accessibilityIdentifier("dashboard-choice-down-\(item.settingText)")
    }
    if multiple || input.canClear {
      Button {
        remove(item)
      } label: {
        Image(systemName: "minus.circle").frame(minWidth: 44, minHeight: 44)
      }
      .disabled(!canEdit)
      .accessibilityLabel("Remove \(label(for: item))")
      .accessibilityIdentifier("dashboard-choice-remove-\(item.settingText)")
    }
  }

  private func select(_ item: DashboardSettingValue) {
    if multiple {
      if selected.contains(item) { remove(item) } else { value = .array(selected + [item]) }
    } else {
      value = item
    }
  }

  private func remove(_ item: DashboardSettingValue) {
    value = multiple ? .array(selected.filter { $0 != item }) : .null
  }

  private func move(_ item: DashboardSettingValue, by distance: Int) {
    var items = selected
    guard let index = items.firstIndex(of: item), items.indices.contains(index + distance) else {
      return
    }
    items.swapAt(index, index + distance)
    value = .array(items)
  }

  @MainActor private func load(offset: Int) async {
    let request = UUID()
    requestID = request
    let requestedQuery = query
    isLoading = true
    error = nil
    if offset == 0 {
      choices = []
      nextOffset = nil
    }
    defer { if requestID == request { isLoading = false } }
    do {
      let pageChoices: [DashboardSettingChoice]
      if input.choicesDynamic, let fieldID = input.fieldID {
        let page = try await model.fetchDashboardSettingChoices(
          dashboardID, fieldID: fieldID, query: requestedQuery, offset: offset,
          schemaRevision: schemaRevision)
        try Task.checkCancellation()
        guard requestID == request, query == requestedQuery else { return }
        guard page.status == "ready" else {
          error = String(
            localized: "Choices could not be loaded. Your selections are kept. Try again.")
          return
        }
        pageChoices = page.choices
        nextOffset = page.hasMore ? page.offset + page.limit : nil
      } else {
        pageChoices = input.choices.filter {
          requestedQuery.isEmpty || $0.label.localizedStandardContains(requestedQuery)
        }
        nextOffset = nil
      }
      guard requestID == request, query == requestedQuery else { return }
      var seen = Set(choices.map(\.value))
      choices.append(contentsOf: pageChoices.filter { seen.insert($0.value).inserted })
      for choice in pageChoices { labels[choice.value] = choice.label }
    } catch is CancellationError {
    } catch {
      guard requestID == request, query == requestedQuery else { return }
      self.error = error.localizedDescription
    }
  }
}
