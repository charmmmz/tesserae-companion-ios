import SwiftUI
import TesseraeKit

struct LineupEditorDraft: Equatable {
    let intent: LineupIntent
    var name: String
    var deviceIDs: [String]
    var pageIDs: [String]
    var dwellMinutes: [String: Int]
    var intervalMinutes: Int
    var firesAtMinutes: Int
    var anchorMinutes: Int
    var bindUnassignedDashboards: Bool

    init(intent: LineupIntent) {
        self.intent = intent
        name = ""
        deviceIDs = []
        pageIDs = []
        dwellMinutes = [:]
        intervalMinutes = 30
        firesAtMinutes = 7 * 60 + 30
        anchorMinutes = 0
        bindUnassignedDashboards = false
    }

    init(lineup: Lineup) {
        intent = lineup.intent ?? .manual
        name = lineup.name
        deviceIDs = lineup.deviceIDs
        pageIDs = lineup.dashboards.map(\.pageID)
        dwellMinutes = Dictionary(
            uniqueKeysWithValues: lineup.dashboards.map {
                ($0.pageID, $0.dwellMinutes)
            }
        )
        intervalMinutes = lineup.intervalMinutes ?? 30
        firesAtMinutes = Self.minutes(from: lineup.firesAt) ?? (7 * 60 + 30)
        anchorMinutes = Self.minutes(from: lineup.anchor) ?? 0
        bindUnassignedDashboards = false
    }

    var takesSingleDashboard: Bool {
        intent == .daily || intent == .interval
    }

    var requiresDisplaySelection: Bool {
        intent == .cycle || intent == .manual
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!requiresDisplaySelection || !deviceIDs.isEmpty)
            && (takesSingleDashboard ? pageIDs.count == 1 : pageIDs.count >= 2)
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter a Lineup name.")
        }
        if pageIDs.isEmpty {
            return String(localized: "Choose at least one Dashboard.")
        }
        if requiresDisplaySelection && deviceIDs.isEmpty {
            return String(localized: "Choose the display this Lineup will control.")
        }
        if takesSingleDashboard && pageIDs.count != 1 {
            return String(localized: "This Lineup type uses exactly one Dashboard.")
        }
        if !takesSingleDashboard && pageIDs.count < 2 {
            return String(localized: "Choose at least two Dashboards.")
        }
        return nil
    }

    var createRequest: LineupCreateRequest {
        LineupCreateRequest(
            intent: intent,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            pageIDs: pageIDs,
            deviceIDs: deviceIDs,
            dwellMinutes: intent == .cycle ? dwellMinutes : nil,
            intervalMinutes: intent == .interval || intent == .cycle
                ? intervalMinutes
                : nil,
            firesAt: intent == .daily ? Self.time(from: firesAtMinutes) : nil,
            anchor: intent == .interval || intent == .cycle
                ? Self.time(from: anchorMinutes)
                : nil,
            bindUnassignedDashboards: requiresDisplaySelection
                && bindUnassignedDashboards
        )
    }

    func patch(comparedTo lineup: Lineup) -> LineupPatchRequest {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let originalPageIDs = lineup.dashboards.map(\.pageID)
        let originalDwell = Dictionary(
            uniqueKeysWithValues: lineup.dashboards.map {
                ($0.pageID, $0.dwellMinutes)
            }
        )
        let changedDwell = intent == .cycle
            ? dwellMinutes.filter { originalDwell[$0.key] != $0.value }
            : [:]

        return LineupPatchRequest(
            name: trimmedName == lineup.name ? nil : trimmedName,
            deviceIDs: Set(deviceIDs) == Set(lineup.deviceIDs) ? nil : deviceIDs,
            pageIDs: pageIDs == originalPageIDs ? nil : pageIDs,
            dwellMinutes: changedDwell.isEmpty ? nil : changedDwell,
            intervalMinutes: (intent == .interval || intent == .cycle)
                && intervalMinutes != lineup.intervalMinutes
                ? intervalMinutes
                : nil,
            firesAt: intent == .daily
                && Self.time(from: firesAtMinutes) != lineup.firesAt
                ? Self.time(from: firesAtMinutes)
                : nil,
            anchor: (intent == .interval || intent == .cycle)
                && Self.time(from: anchorMinutes) != (lineup.anchor ?? "00:00")
                ? Self.time(from: anchorMinutes)
                : nil
        )
    }

    static func time(from minutes: Int) -> String {
        let normalized = ((minutes % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", normalized / 60, normalized % 60)
    }

    static func minutes(from time: String?) -> Int? {
        guard let time else { return nil }
        let parts = time.split(separator: ":")
        guard parts.count >= 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute)
        else {
            return nil
        }
        return hour * 60 + minute
    }
}

struct LineupCreateFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [LineupIntent] = []

    let onSaved: (Lineup) -> Void

    var body: some View {
        NavigationStack(path: $path) {
            LineupIntentPicker { intent in
                path.append(intent)
            }
            .navigationDestination(for: LineupIntent.self) { intent in
                LineupEditorView(intent: intent) { lineup in
                    onSaved(lineup)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct LineupEditFlow: View {
    @Environment(\.dismiss) private var dismiss

    let lineupID: String
    let onSaved: (Lineup) -> Void

    var body: some View {
        NavigationStack {
            LineupEditorView(lineupID: lineupID) { lineup in
                onSaved(lineup)
                dismiss()
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

private struct LineupIntentPicker: View {
    let onSelect: (LineupIntent) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose how this Lineup should behave.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)

                ForEach(LineupIntent.allAuthoringCases, id: \.self) { intent in
                    Button {
                        onSelect(intent)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: intent.editorSymbolName)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(TesseraeTheme.accent)
                                .frame(width: 44, height: 44)
                                .background(
                                    TesseraeTheme.accent.opacity(0.11),
                                    in: RoundedRectangle(
                                        cornerRadius: 13,
                                        style: .continuous
                                    )
                                )

                            VStack(alignment: .leading, spacing: 3) {
                                Text(intent.editorName)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(intent.editorDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.leading)
                            }

                            Spacer(minLength: 8)

                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tesseraeCard()
                    .accessibilityIdentifier("lineup-intent-\(intent.rawValue)")
                }
            }
            .padding(16)
        }
        .navigationTitle("New Lineup")
        .navigationBarTitleDisplayMode(.inline)
        .tesseraeScreenBackground()
    }
}

private struct LineupEditorView: View {
    private enum Purpose {
        case create(LineupIntent)
        case edit(String)

        var lineupID: String? {
            if case let .edit(id) = self { id } else { nil }
        }
    }

    private enum PresentedAlert: Identifiable {
        case conflict
        case permission
        case failure(String)

        var id: String {
            switch self {
            case .conflict: "conflict"
            case .permission: "permission"
            case let .failure(message): "failure-\(message)"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var draft: LineupEditorDraft
    @State private var baseline: VersionedLineup?
    @State private var isLoading: Bool
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var presentedAlert: PresentedAlert?

    private let purpose: Purpose
    private let onSaved: (Lineup) -> Void

    init(intent: LineupIntent, onSaved: @escaping (Lineup) -> Void) {
        purpose = .create(intent)
        self.onSaved = onSaved
        _draft = State(initialValue: LineupEditorDraft(intent: intent))
        _isLoading = State(initialValue: false)
    }

    init(lineupID: String, onSaved: @escaping (Lineup) -> Void) {
        purpose = .edit(lineupID)
        self.onSaved = onSaved
        _draft = State(initialValue: LineupEditorDraft(intent: .manual))
        _isLoading = State(initialValue: true)
    }

    private var navigationTitle: String {
        switch purpose {
        case .create:
            String(localized: "New Lineup")
        case .edit:
            String(localized: "Edit Lineup")
        }
    }

    private var saveTitle: String {
        switch purpose {
        case .create: String(localized: "Create")
        case .edit: String(localized: "Save")
        }
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading Lineup…")
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn’t Load Lineup", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try Again") {
                        Task { await loadForEditing() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                LineupEditorForm(
                    draft: $draft,
                    displays: model.sortedDisplays,
                    dashboards: model.sortedDashboards,
                    isCreating: baseline == nil
                )
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .tesseraeScreenBackground()
        .interactiveDismissDisabled(isSaving)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isLoading || isSaving || !draft.isValid)
                .accessibilityIdentifier("lineup-editor-save")
            }
        }
        .overlay {
            if isSaving {
                ProgressView()
                    .padding(18)
                    .background(.regularMaterial, in: Circle())
                    .accessibilityLabel("Saving Lineup")
            }
        }
        .task(id: purpose.lineupID) {
            if purpose.lineupID != nil, baseline == nil {
                await loadForEditing()
            }
        }
        .alert(item: $presentedAlert) { alert in
            switch alert {
            case .conflict:
                Alert(
                    title: Text("Lineup Changed"),
                    message: Text(
                        "This Lineup was edited somewhere else. Reload the latest version before saving again."
                    ),
                    primaryButton: .default(Text("Reload")) {
                        Task { await loadForEditing() }
                    },
                    secondaryButton: .cancel()
                )
            case .permission:
                Alert(
                    title: Text("Permission Required"),
                    message: Text(
                        "Enable Create and edit Lineups for this iPhone in Tesserae Settings → Companion, then try again. You do not need to pair again."
                    ),
                    primaryButton: .default(Text("Open Tesserae")) {
                        if let url = lineupAuthoringWebURL(model: model) {
                            openURL(url)
                        }
                    },
                    secondaryButton: .cancel()
                )
            case let .failure(message):
                Alert(
                    title: Text("Couldn’t Save Lineup"),
                    message: Text(message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func loadForEditing() async {
        guard let lineupID = purpose.lineupID else { return }
        isLoading = true
        loadError = nil
        do {
            let versioned = try await model.fetchLineupForEditing(lineupID)
            guard !Task.isCancelled else { return }
            baseline = versioned
            draft = LineupEditorDraft(lineup: versioned.lineup)
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard draft.isValid, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let outcome: AppModel.LineupSaveOutcome
        if let baseline {
            outcome = await model.updateLineup(
                id: baseline.lineup.id,
                eTag: baseline.eTag,
                patch: draft.patch(comparedTo: baseline.lineup)
            )
        } else {
            outcome = await model.createLineup(draft.createRequest)
        }

        switch outcome {
        case let .saved(lineup):
            onSaved(lineup)
        case .conflict:
            presentedAlert = .conflict
        case .permissionRequired:
            presentedAlert = .permission
        case let .failed(message):
            presentedAlert = .failure(message)
        }
    }
}

private struct LineupEditorForm: View {
    private enum FocusedField: Hashable {
        case name
    }

    @Binding var draft: LineupEditorDraft

    @State private var durationDashboard: DashboardSummary?
    @FocusState private var focusedField: FocusedField?

    let displays: [DisplaySummary]
    let dashboards: [DashboardSummary]
    let isCreating: Bool

    private var selectedDashboards: [DashboardSummary] {
        let byID = Dictionary(uniqueKeysWithValues: dashboards.map { ($0.id, $0) })
        return draft.pageIDs.compactMap { byID[$0] }
    }

    private var displaySummary: String {
        switch draft.deviceIDs.count {
        case 0:
            String(localized: "Choose")
        case 1:
            displays.first { $0.id == draft.deviceIDs[0] }?.name
                ?? draft.deviceIDs[0]
        default:
            String(localized: "\(draft.deviceIDs.count) displays")
        }
    }

    private var dashboardSummary: String {
        if let first = selectedDashboards.first, draft.takesSingleDashboard {
            return first.name
        }
        return draft.pageIDs.isEmpty
            ? String(localized: "Choose")
            : String(localized: "\(draft.pageIDs.count) dashboards")
    }

    private var hasUnassignedDashboard: Bool {
        let knownDisplayIDs = Set(displays.map(\.id))
        return selectedDashboards.contains { dashboard in
            dashboard.deviceIDs.allSatisfy { !knownDisplayIDs.contains($0) }
        }
    }

    private var canChooseDashboards: Bool {
        !draft.requiresDisplaySelection || !draft.deviceIDs.isEmpty || displays.isEmpty
    }

    var body: some View {
        Form {
            Section("Lineup") {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("lineup-editor-name")

                LabeledContent("Type", value: draft.intent.editorName)
            }

            if draft.requiresDisplaySelection {
                Section {
                    NavigationLink {
                        LineupDisplayPicker(
                            displays: displays,
                            selection: $draft.deviceIDs
                        )
                    } label: {
                        LabeledContent("Display", value: displaySummary)
                    }
                    .accessibilityIdentifier("lineup-editor-displays")
                } header: {
                    Text("Target")
                } footer: {
                    Text(
                        "This Lineup plays as one ordered set on a single display."
                    )
                }
            }

            Section("Dashboards") {
                NavigationLink {
                    LineupDashboardPicker(
                        intent: draft.intent,
                        targetDeviceIDs: draft.deviceIDs,
                        isCreating: isCreating,
                        displays: displays,
                        dashboards: dashboards,
                        selection: $draft.pageIDs
                    )
                } label: {
                    LabeledContent("Selection", value: dashboardSummary)
                }
                .accessibilityIdentifier("lineup-editor-dashboards")
                .disabled(!canChooseDashboards)

                ForEach(Array(selectedDashboards.enumerated()), id: \.element.id) { index, dashboard in
                    if draft.intent == .cycle {
                        Button {
                            durationDashboard = dashboard
                        } label: {
                            HStack(spacing: 12) {
                                Text(index + 1, format: .number)
                                    .font(.caption.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 28, height: 28)
                                    .background(TesseraeTheme.accent, in: Circle())

                                PhosphorIcon(
                                    name: dashboard.iconName,
                                    size: 17,
                                    color: TesseraeTheme.accent,
                                    fallbackSystemName: "rectangle.grid.2x2"
                                )

                                Text(dashboard.name)
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text(
                                    durationLabel(
                                        draft.dwellMinutes[dashboard.id]
                                            ?? draft.intervalMinutes
                                    )
                                )
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(TesseraeTheme.accent)

                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityLabel(
                            String(
                                localized: "\(dashboard.name), \(draft.dwellMinutes[dashboard.id] ?? draft.intervalMinutes) minutes"
                            )
                        )
                    } else if !draft.takesSingleDashboard {
                        HStack(spacing: 12) {
                            Text(index + 1, format: .number)
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(TesseraeTheme.accent, in: Circle())
                            Label {
                                Text(dashboard.name)
                            } icon: {
                                PhosphorIcon(
                                    name: dashboard.iconName,
                                    size: 17,
                                    color: TesseraeTheme.accent,
                                    fallbackSystemName: "rectangle.grid.2x2"
                                )
                            }
                        }
                    }
                }

                if draft.requiresDisplaySelection && !canChooseDashboards {
                    Label("Choose a display first.", systemImage: "arrow.up")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            switch draft.intent {
            case .daily:
                Section("Show every day at") {
                    DatePicker(
                        "Time",
                        selection: timeBinding(for: \.firesAtMinutes),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .sensoryFeedback(
                        .selection,
                        trigger: draft.firesAtMinutes
                    ) { _, _ in
                        TesseraeHapticSettings.isEnabled
                    }
                }
            case .interval:
                Section {
                    LineupDurationWheel(minutes: $draft.intervalMinutes)
                        .accessibilityIdentifier("lineup-editor-interval")
                } header: {
                    Text("Refresh interval")
                } footer: {
                    Text("Tesserae re-renders this Dashboard throughout the day.")
                }
            case .cycle, .manual:
                EmptyView()
            }

            if hasUnassignedDashboard {
                Section {
                    Label(
                        isCreating && draft.requiresDisplaySelection
                            ? "Unassigned Dashboards will be linked to the selected display when this Lineup is created."
                            : "This Dashboard is not assigned to a display yet.",
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } footer: {
                    Text(
                        "Dashboards already assigned elsewhere are never moved."
                    )
                }
            }

            if let validationMessage = draft.validationMessage {
                Section {
                    Label(validationMessage, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else {
                        return
                    }
                    focusedField = nil
                }
        )
        .task {
            if isCreating,
               draft.requiresDisplaySelection,
               draft.deviceIDs.isEmpty,
               displays.count == 1,
               let display = displays.first
            {
                draft.deviceIDs = [display.id]
            }
            updateAutomaticBinding()
        }
        .onChange(of: draft.deviceIDs) { oldValue, newValue in
            guard draft.requiresDisplaySelection, oldValue != newValue else { return }
            let compatibleIDs = Set(
                dashboards.filter { dashboard in
                    dashboard.deviceIDs.isEmpty
                        || newValue.contains(where: dashboard.deviceIDs.contains)
                }.map(\.id)
            )
            draft.pageIDs.removeAll { !compatibleIDs.contains($0) }
            draft.dwellMinutes = draft.dwellMinutes.filter {
                draft.pageIDs.contains($0.key)
            }
            updateAutomaticBinding()
        }
        .onChange(of: draft.pageIDs) { _, _ in
            if draft.intent == .cycle {
                for pageID in draft.pageIDs where draft.dwellMinutes[pageID] == nil {
                    draft.dwellMinutes[pageID] = 5
                }
            }
            updateAutomaticBinding()
        }
        .sheet(item: $durationDashboard) { dashboard in
            NavigationStack {
                LineupDwellEditor(
                    dashboardName: dashboard.name,
                    minutes: dwellBinding(for: dashboard.id)
                )
            }
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private func updateAutomaticBinding() {
        draft.bindUnassignedDashboards = isCreating
            && draft.requiresDisplaySelection
            && !draft.deviceIDs.isEmpty
            && hasUnassignedDashboard
    }

    private func durationLabel(_ minutes: Int) -> String {
        if minutes < 60 {
            return String(localized: "\(minutes) min")
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? String(localized: "\(hours) hr")
            : String(localized: "\(hours) hr \(remainder) min")
    }

    private func dwellBinding(for dashboardID: String) -> Binding<Int> {
        Binding(
            get: {
                draft.dwellMinutes[dashboardID] ?? draft.intervalMinutes
            },
            set: { draft.dwellMinutes[dashboardID] = $0 }
        )
    }

    private func timeBinding(
        for keyPath: WritableKeyPath<LineupEditorDraft, Int>
    ) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: .now)
                return calendar.date(
                    byAdding: .minute,
                    value: draft[keyPath: keyPath],
                    to: start
                ) ?? start
            },
            set: { date in
                let parts = Calendar.current.dateComponents(
                    [.hour, .minute],
                    from: date
                )
                draft[keyPath: keyPath] = (parts.hour ?? 0) * 60
                    + (parts.minute ?? 0)
            }
        )
    }
}

private struct LineupDisplayPicker: View {
    @Environment(\.dismiss) private var dismiss

    let displays: [DisplaySummary]
    @Binding var selection: [String]

    var body: some View {
        List {
            Section("Displays") {
                ForEach(displays) { display in
                    Button {
                        selection = [display.id]
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            PhosphorIcon(
                                name: display.canonicalIconName,
                                size: 20,
                                color: TesseraeTheme.accent,
                                fallbackSystemName: "display"
                            )
                            .frame(width: 42, height: 42)
                            .background(
                                TesseraeTheme.accent.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(display.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("Display")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selection.contains(display.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(TesseraeTheme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("lineup-editor-display-\(display.id)")
                }
            }

            if displays.isEmpty {
                ContentUnavailableView(
                    "No Displays",
                    systemImage: "display.slash",
                    description: Text("Add a display in Tesserae before creating this Lineup.")
                )
            }
        }
        .navigationTitle("Displays")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct LineupDashboardPicker: View {
    @Environment(\.dismiss) private var dismiss

    let intent: LineupIntent
    let targetDeviceIDs: [String]
    let isCreating: Bool
    let displays: [DisplaySummary]
    let dashboards: [DashboardSummary]
    @Binding var selection: [String]

    @State private var query = ""
    @State private var hapticEvent = TesseraeHapticEvent()

    private var isSingleSelection: Bool {
        intent == .daily || intent == .interval
    }

    private var selectedDashboards: [DashboardSummary] {
        let byID = Dictionary(uniqueKeysWithValues: dashboards.map { ($0.id, $0) })
        return selection.compactMap { byID[$0] }
    }

    private var incompatibleCount: Int {
        dashboards.filter { !selection.contains($0.id) && !isCompatible($0) }.count
    }

    private var sections: [LineupDashboardPickerSection] {
        let compatible = dashboards.filter(isCompatible).filter(matchesSearch)
        let pool = isSingleSelection
            ? compatible
            : compatible.filter { !selection.contains($0.id) }
        let displayIDs = Set(displays.map(\.id))

        if !isSingleSelection, let targetID = targetDeviceIDs.first {
            var result: [LineupDashboardPickerSection] = []
            if let display = displays.first(where: { $0.id == targetID }) {
                let bound = pool.filter { $0.deviceIDs.contains(targetID) }
                if !bound.isEmpty {
                    result.append(
                        .init(
                            id: "display-\(targetID)",
                            title: display.name,
                            subtitle: "Assigned to this display",
                            iconName: display.canonicalIconName,
                            dashboards: bound
                        )
                    )
                }
            }
            let unassigned = pool.filter {
                $0.deviceIDs.allSatisfy { !displayIDs.contains($0) }
            }
            if !unassigned.isEmpty {
                result.append(
                    .init(
                        id: "unassigned",
                        title: "Unassigned",
                        subtitle: isCreating
                            ? "Will be linked when you create the Lineup"
                            : "Not linked to a display",
                        iconName: "rectangle.dashed",
                        dashboards: unassigned
                    )
                )
            }
            return result
        }

        var result = displays.compactMap { display -> LineupDashboardPickerSection? in
            let items = pool.filter { dashboard in
                let recognized = dashboard.deviceIDs.filter(displayIDs.contains)
                return recognized.count == 1 && recognized.first == display.id
            }
            guard !items.isEmpty else { return nil }
            return .init(
                id: "display-\(display.id)",
                title: display.name,
                subtitle: "Dashboards on this display",
                iconName: display.canonicalIconName,
                dashboards: items
            )
        }
        let shared = pool.filter {
            $0.deviceIDs.filter(displayIDs.contains).count > 1
        }
        if !shared.isEmpty {
            result.append(
                .init(
                    id: "shared",
                    title: "Shared",
                    subtitle: "Available on multiple displays",
                    iconName: "rectangle.on.rectangle",
                    dashboards: shared
                )
            )
        }
        let unassigned = pool.filter {
            $0.deviceIDs.allSatisfy { !displayIDs.contains($0) }
        }
        if !unassigned.isEmpty {
            result.append(
                .init(
                    id: "unassigned",
                    title: "Unassigned",
                    subtitle: "Not linked to a display",
                    iconName: "rectangle.dashed",
                    dashboards: unassigned
                )
            )
        }
        return result
    }

    var body: some View {
        List {
            if !isSingleSelection, !selectedDashboards.isEmpty {
                Section {
                    ForEach(selectedDashboards) { dashboard in
                        dashboardRow(
                            dashboard,
                            selected: true,
                            order: selection.firstIndex(of: dashboard.id).map { $0 + 1 }
                        )
                        .accessibilityIdentifier(
                            "lineup-editor-selected-dashboard-\(dashboard.id)"
                        )
                        .accessibilityHint(
                            "Touch and hold to reorder, or swipe left to remove."
                        )
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                selection.removeAll { $0 == dashboard.id }
                            }
                        }
                    }
                    .onMove { source, destination in
                        let previousSelection = selection
                        selection.move(fromOffsets: source, toOffset: destination)
                        if selection != previousSelection {
                            hapticEvent.trigger(.rigidImpact)
                        }
                    }
                } header: {
                    Text("Selected · \(selection.count)")
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.dashboards) { dashboard in
                        Button {
                            if isSingleSelection {
                                selection = [dashboard.id]
                                dismiss()
                            } else {
                                selection.append(dashboard.id)
                            }
                            hapticEvent.trigger(.selection)
                        } label: {
                            dashboardRow(
                                dashboard,
                                selected: selection.contains(dashboard.id),
                                order: selection.firstIndex(of: dashboard.id).map { $0 + 1 }
                            )
                        }
                        .accessibilityIdentifier("lineup-editor-dashboard-\(dashboard.id)")
                    }
                } header: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            Text(section.subtitle)
                                .font(.caption2)
                                .textCase(nil)
                        }
                    } icon: {
                        PhosphorIcon(
                            name: section.iconName,
                            size: 15,
                            color: TesseraeTheme.accent,
                            fallbackSystemName: "display"
                        )
                    }
                }
            }

            if sections.isEmpty,
               (isSingleSelection || selectedDashboards.isEmpty)
            {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No Dashboards",
                        systemImage: "rectangle.grid.2x2",
                        description: Text(
                            isSingleSelection
                                ? "Create a Dashboard in Tesserae first."
                                : "No compatible Dashboards are available for this display."
                        )
                    )
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }

            if incompatibleCount > 0, intent != .manual {
                Section {
                    Label(
                        String(
                            localized: "\(incompatibleCount) Dashboards assigned only to other displays are hidden."
                        ),
                        systemImage: "info.circle"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Dashboards")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search Dashboards")
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private func isCompatible(_ dashboard: DashboardSummary) -> Bool {
        guard !isSingleSelection,
              let targetID = targetDeviceIDs.first
        else {
            return true
        }
        let knownDisplayIDs = Set(displays.map(\.id))
        let recognizedBindings = dashboard.deviceIDs.filter(knownDisplayIDs.contains)
        return recognizedBindings.isEmpty || recognizedBindings.contains(targetID)
    }

    private func matchesSearch(_ dashboard: DashboardSummary) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return dashboard.name.localizedCaseInsensitiveContains(trimmed)
            || dashboard.kind.rawValue.localizedCaseInsensitiveContains(trimmed)
    }

    private func dashboardRow(
        _ dashboard: DashboardSummary,
        selected: Bool,
        order: Int?
    ) -> some View {
        HStack(spacing: 12) {
            PhosphorIcon(
                name: dashboard.iconName,
                size: 19,
                color: TesseraeTheme.accent,
                fallbackSystemName: "rectangle.grid.2x2"
            )
            .frame(width: 42, height: 42)
            .background(
                TesseraeTheme.accent.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(dashboard.kind == .canvas ? "Canvas" : "Grid")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let order, !isSingleSelection {
                Text(order, format: .number)
                    .font(.caption.monospacedDigit().weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 25, height: 25)
                    .background(TesseraeTheme.accent, in: Circle())
            } else if selected {
                Image(systemName: "checkmark")
                    .foregroundStyle(TesseraeTheme.accent)
            } else if !isSingleSelection {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(TesseraeTheme.accent)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct LineupDashboardPickerSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let iconName: String?
    let dashboards: [DashboardSummary]
}

private struct LineupDwellEditor: View {
    @Environment(\.dismiss) private var dismiss

    let dashboardName: String
    @Binding var minutes: Int

    var body: some View {
        Form {
            Section {
                LineupDurationWheel(minutes: $minutes)
            } header: {
                Text("Time on screen")
            } footer: {
                Text("How long \(dashboardName) stays visible before the rotation advances.")
            }
        }
        .navigationTitle(dashboardName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .fontWeight(.semibold)
            }
        }
    }
}

private struct LineupDurationWheel: View {
    @Binding var minutes: Int

    private var hourBinding: Binding<Int> {
        Binding(
            get: { min(minutes / 60, 24) },
            set: { hours in
                if hours == 24 {
                    minutes = 1_440
                } else {
                    minutes = max(1, hours * 60 + min(minutes % 60, 59))
                }
            }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { minutes == 1_440 ? 0 : minutes % 60 },
            set: { minute in
                let hours = min(minutes / 60, 24)
                minutes = hours == 24
                    ? 1_440
                    : max(1, hours * 60 + minute)
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hourBinding) {
                ForEach(0...24, id: \.self) { value in
                    Text("\(value) hr").tag(value)
                }
            }
            .pickerStyle(.wheel)

            Picker("Minutes", selection: minuteBinding) {
                ForEach(0...59, id: \.self) { value in
                    Text("\(value) min").tag(value)
                }
            }
            .pickerStyle(.wheel)
        }
        .frame(height: 150)
        .sensoryFeedback(.selection, trigger: minutes) { _, _ in
            TesseraeHapticSettings.isEnabled
        }
    }
}

@MainActor
func lineupAuthoringWebURL(model: AppModel) -> URL? {
    guard let instance = model.activeInstance else { return nil }
    let destination = model.lineupAuthoringSettingsURL ?? instance.webURL
    return URL(
        string: destination,
        relativeTo: instance.baseURL
    )?.absoluteURL
}

private extension LineupIntent {
    static let allAuthoringCases: [LineupIntent] = [
        .daily,
        .interval,
        .cycle,
        .manual,
    ]

    var editorName: String {
        switch self {
        case .daily: String(localized: "Daily")
        case .interval: String(localized: "Keep Fresh")
        case .cycle: String(localized: "Cycle")
        case .manual: String(localized: "Manual")
        }
    }

    var editorSymbolName: String {
        switch self {
        case .daily: "calendar"
        case .interval: "timer"
        case .cycle: "arrow.triangle.2.circlepath"
        case .manual: "hand.tap"
        }
    }

    var editorDescription: String {
        switch self {
        case .daily:
            String(localized: "Show one Dashboard at a set time each day.")
        case .interval:
            String(localized: "Keep one Dashboard fresh on a repeating interval.")
        case .cycle:
            String(localized: "Cycle through an ordered set of Dashboards automatically.")
        case .manual:
            String(localized: "Switch between an ordered set of Dashboards by hand.")
        }
    }
}

#if DEBUG
#Preview("New Lineup") {
    TesseraePreviewHost {
        LineupCreateFlow { _ in }
    }
}
#endif
