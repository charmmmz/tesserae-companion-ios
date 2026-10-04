import SwiftUI
import TesseraeKit

struct LineupEditorDraft: Equatable {
    let intent: LineupIntent
    let minimumDashboardCount: Int
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
        minimumDashboardCount = intent == .daily || intent == .interval ? 1 : 2
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
        minimumDashboardCount = 1
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
            && (takesSingleDashboard ? pageIDs.count == 1 : pageIDs.count >= minimumDashboardCount)
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
        if !takesSingleDashboard && pageIDs.count < minimumDashboardCount {
            return String(localized: "Choose at least two Dashboards.")
        }
        return nil
    }

    func hasChanges(comparedTo original: Self) -> Bool {
        if name.trimmingCharacters(in: .whitespacesAndNewlines)
            != original.name.trimmingCharacters(in: .whitespacesAndNewlines)
            || Set(deviceIDs) != Set(original.deviceIDs)
            || pageIDs != original.pageIDs
        {
            return true
        }
        switch intent {
        case .daily:
            return firesAtMinutes != original.firesAtMinutes
        case .interval:
            return intervalMinutes != original.intervalMinutes
        case .cycle:
            return anchorMinutes != original.anchorMinutes || pageIDs.contains {
                (dwellMinutes[$0] ?? intervalMinutes)
                    != (original.dwellMinutes[$0] ?? original.intervalMinutes)
            }
        case .manual:
            return false
        }
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

// DatePicker needs a Date, but the API takes server wall-clock HH:mm. A fixed UTC
// reference avoids shifting the chosen hour on the phone's DST transition days.
enum LineupEditorClock {
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func date(for minutes: Int) -> Date {
        Date(timeIntervalSince1970: Double(((minutes % 1_440) + 1_440) % 1_440) * 60)
    }

    static func minutes(from date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }
}

struct LineupCreateFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path: [LineupIntent] = []
    @State private var session = LineupEditingSession()

    let onSaved: (Lineup) -> Void

    var body: some View {
        NavigationStack(path: $path) {
            LineupIntentPicker { intent in
                path.append(intent)
            }
            .navigationDestination(for: LineupIntent.self) { intent in
                LineupEditorView(intent: intent, session: session, onExit: {
                    if session.canExit(to: .back) { exit(.back) }
                }) { lineup in
                    onSaved(lineup)
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if session.canExit(to: .close) { exit(.close) }
                    }
                    .disabled(session.isSaving)
                }
            }
        }
        .modifier(LineupExitProtection(session: session, onExit: exit))
    }

    private func exit(_ destination: LineupEditingSession.ExitDestination) {
        switch destination {
        case .back:
            if !path.isEmpty { path.removeLast() }
        case .close:
            dismiss()
        }
    }
}

struct LineupEditFlow: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session = LineupEditingSession()

    let lineupID: String
    let onSaved: (Lineup) -> Void

    var body: some View {
        NavigationStack {
            LineupEditorView(lineupID: lineupID, session: session, onExit: {
                if session.canExit(to: .close) { dismiss() }
            }) { lineup in
                onSaved(lineup)
                dismiss()
            }
        }
        .modifier(LineupExitProtection(session: session) { _ in dismiss() })
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
    @State private var originalDraft: LineupEditorDraft?
    @State private var isLoading: Bool
    @State private var loadError: String?
    @State private var presentedAlert: PresentedAlert?

    private let purpose: Purpose
    private let session: LineupEditingSession
    private let onExit: () -> Void
    private let onSaved: (Lineup) -> Void

    private var isSaving: Bool { session.isSaving }

    init(intent: LineupIntent, session: LineupEditingSession, onExit: @escaping () -> Void, onSaved: @escaping (Lineup) -> Void) {
        purpose = .create(intent)
        self.session = session
        self.onExit = onExit
        self.onSaved = onSaved
        _draft = State(initialValue: LineupEditorDraft(intent: intent))
        _isLoading = State(initialValue: false)
    }

    init(lineupID: String, session: LineupEditingSession, onExit: @escaping () -> Void, onSaved: @escaping (Lineup) -> Void) {
        purpose = .edit(lineupID)
        self.session = session
        self.onExit = onExit
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
                .disabled(isSaving)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .tesseraeScreenBackground()
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: onExit) {
                    if case .create = purpose {
                        Label("Back", systemImage: "chevron.left")
                            .labelStyle(.iconOnly)
                    } else {
                        Text("Cancel")
                    }
                }
                .disabled(isSaving)
                .accessibilityIdentifier("lineup-editor-exit")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(saveTitle) {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(isLoading || isSaving || !draft.isValid)
                .accessibilityHint(draft.validationMessage ?? "")
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
            } else if originalDraft == nil {
                if draft.requiresDisplaySelection,
                   model.sortedDisplays.count == 1,
                   let display = model.sortedDisplays.first {
                    draft.deviceIDs = [display.id]
                }
                originalDraft = draft
            }
        }
        .onChange(of: draft) { _, _ in updateDirtyState() }
        .onChange(of: originalDraft) { _, _ in updateDirtyState() }
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

    private func updateDirtyState() {
        session.hasChanges = originalDraft.map { draft.hasChanges(comparedTo: $0) } ?? false
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
            originalDraft = draft
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func save() async {
        guard draft.isValid, !isSaving else { return }
        session.isSaving = true
        defer { session.isSaving = false }

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
            session.hasChanges = false
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
    @State private var showsTiming = false
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
            draft.requiresDisplaySelection
                ? String(localized: "Choose")
                : String(localized: "Follow Dashboard")
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
        switch draft.pageIDs.count {
        case 0: return String(localized: "Choose")
        case 1: return String(localized: "1 dashboard")
        default: return String(localized: "\(draft.pageIDs.count) dashboards")
        }
    }

    private var hasUnassignedDashboard: Bool {
        let knownDisplayIDs = Set(displays.map(\.id))
        return selectedDashboards.contains { dashboard in
            dashboard.deviceIDs.allSatisfy { !knownDisplayIDs.contains($0) }
        }
    }

    private var canChooseDashboards: Bool {
        !draft.requiresDisplaySelection || !draft.deviceIDs.isEmpty
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .focused($focusedField, equals: .name)
                    .accessibilityIdentifier("lineup-editor-name")

                if draft.takesSingleDashboard {
                    dashboardSelectionLink
                }

                displaySelectionLink
            } header: {
                Text(draft.intent.editorName)
            } footer: {
                if draft.requiresDisplaySelection && displays.isEmpty {
                    Text("Add a display in Tesserae to continue.")
                } else if draft.takesSingleDashboard && hasUnassignedDashboard && draft.deviceIDs.isEmpty {
                    Text("This Dashboard is not assigned to a display yet.")
                }
            }

            if !draft.takesSingleDashboard && canChooseDashboards {
                Section {
                    dashboardSelectionLink
                    orderedDashboards
                } header: {
                    Text("Dashboards")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if draft.pageIDs.count < draft.minimumDashboardCount {
                            Text("Choose at least two Dashboards.")
                        } else if draft.intent == .cycle {
                            Text("Tap a Dashboard to change its time on screen.")
                        }

                        if hasUnassignedDashboard {
                            Text(
                                isCreating
                                    ? "Unassigned Dashboards will be linked to the selected display when this Lineup is created."
                                    : "This Dashboard is not assigned to a display yet."
                            )
                        }
                    }
                }
            }

            scheduleSection
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
            LineupDwellEditor(
                dashboardName: dashboard.name,
                minutes: dwellBinding(for: dashboard.id)
            )
            .presentationDragIndicator(.visible)
        }
    }

    private var displaySelectionLink: some View {
        NavigationLink {
            LineupDisplayPicker(
                displays: displays,
                allowsDashboardBindings: !draft.requiresDisplaySelection,
                selection: $draft.deviceIDs
            )
        } label: {
            LabeledContent {
                Text(displaySummary)
            } label: {
                Text(draft.requiresDisplaySelection ? "Display" : "Displays")
            }
        }
        .accessibilityIdentifier("lineup-editor-displays")
    }

    private var dashboardSelectionLink: some View {
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
            LabeledContent {
                Text(dashboardSummary)
            } label: {
                Text(draft.takesSingleDashboard ? "Dashboard" : "Selection")
            }
        }
        .accessibilityIdentifier("lineup-editor-dashboards")
    }

    private var orderedDashboards: some View {
        ForEach(Array(selectedDashboards.enumerated()), id: \.element.id) { index, dashboard in
            if draft.intent == .cycle {
                Button {
                    durationDashboard = dashboard
                } label: {
                    HStack(spacing: 12) {
                        dashboardOrder(index)

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
                        .fixedSize()

                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(
                    String(
                        localized: "\(dashboard.name), \(draft.dwellMinutes[dashboard.id] ?? draft.intervalMinutes) minutes"
                    )
                )
                .accessibilityHint("Change time on screen")
                .accessibilityIdentifier("lineup-editor-duration-\(dashboard.id)")
            } else if !draft.takesSingleDashboard {
                HStack(spacing: 12) {
                    dashboardOrder(index)
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
    }

    private func dashboardOrder(_ index: Int) -> some View {
        Text("\(index + 1).")
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(minWidth: 20, alignment: .leading)
    }

    @ViewBuilder
    private var scheduleSection: some View {
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
                .environment(\.calendar, LineupEditorClock.calendar)
                .environment(\.timeZone, .gmt)
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
        case .cycle:
            Section {
                DisclosureGroup(isExpanded: $showsTiming) {
                    Text("Starts each day at")
                        .font(.subheadline)
                    DatePicker(
                        "Starts each day at",
                        selection: timeBinding(for: \.anchorMinutes),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.wheel)
                    .environment(\.calendar, LineupEditorClock.calendar)
                    .environment(\.timeZone, .gmt)
                    .accessibilityIdentifier("lineup-editor-anchor")

                    Text("Starts with the first Dashboard at this time. The cycle pauses before then each day. Times use the Tesserae server’s time zone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } label: {
                    LabeledContent("Timing", value: LineupEditorDraft.time(from: draft.anchorMinutes))
                }
                .accessibilityIdentifier("lineup-editor-timing")
            }
        case .manual:
            EmptyView()
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
            get: { LineupEditorClock.date(for: draft[keyPath: keyPath]) },
            set: { draft[keyPath: keyPath] = LineupEditorClock.minutes(from: $0) }
        )
    }
}

private struct LineupDisplayPicker: View {
    @Environment(\.dismiss) private var dismiss

    let displays: [DisplaySummary]
    let allowsDashboardBindings: Bool
    @Binding var selection: [String]

    var body: some View {
        List {
            if allowsDashboardBindings {
                Section {
                    Button {
                        selection = []
                        dismiss()
                    } label: {
                        HStack {
                            Text("Follow Dashboard")
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if selection.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(TesseraeTheme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(selection.isEmpty ? .isSelected : [])
                    .accessibilityIdentifier("lineup-editor-inherit-displays")
                } footer: {
                    Text("Other displays apply only to this Lineup.")
                }
            }

            Section("Displays") {
                ForEach(displays) { display in
                    Button {
                        if allowsDashboardBindings {
                            if selection.contains(display.id) {
                                selection.removeAll { $0 == display.id }
                            } else {
                                selection.append(display.id)
                            }
                        } else {
                            selection = [display.id]
                            dismiss()
                        }
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

                            Text(display.name)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if selection.contains(display.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(TesseraeTheme.accent)
                            }
                        }
                    }
                    .accessibilityAddTraits(selection.contains(display.id) ? .isSelected : [])
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
        .toolbar {
            if allowsDashboardBindings {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("lineup-editor-displays-done")
                }
            }
        }
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
                            subtitle: nil,
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
                subtitle: nil,
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
                    subtitle: nil,
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
                        Menu {
                            Button("Move Up", systemImage: "arrow.up") {
                                move(dashboard.id, by: -1)
                            }
                            .disabled(selection.first == dashboard.id)
                            Button("Move Down", systemImage: "arrow.down") {
                                move(dashboard.id, by: 1)
                            }
                            .disabled(selection.last == dashboard.id)
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                selection.removeAll { $0 == dashboard.id }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                dashboardRow(
                                    dashboard,
                                    selected: true,
                                    order: selection.firstIndex(of: dashboard.id).map { $0 + 1 }
                                )
                                Image(systemName: "ellipsis")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityLabel(dashboard.name)
                        .accessibilityValue(
                            Text("Dashboard \((selection.firstIndex(of: dashboard.id) ?? 0) + 1) of \(selection.count)")
                        )
                        .accessibilityIdentifier(
                            "lineup-editor-selected-dashboard-\(dashboard.id)"
                        )
                        .accessibilityHint(
                            "Drag to reorder, or use the menu to move or remove."
                        )
                        .accessibilityActions {
                            if selection.first != dashboard.id {
                                Button("Move Up") { move(dashboard.id, by: -1) }
                            }
                            if selection.last != dashboard.id {
                                Button("Move Down") { move(dashboard.id, by: 1) }
                            }
                            Button("Remove") { selection.removeAll { $0 == dashboard.id } }
                        }
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
                        .accessibilityAddTraits(selection.contains(dashboard.id) ? .isSelected : [])
                    }
                } header: {
                    Label {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(section.title)
                            if let subtitle = section.subtitle {
                                Text(subtitle)
                                    .font(.caption2)
                                    .textCase(nil)
                            }
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

        }
        .navigationTitle("Dashboards")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isSingleSelection {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("lineup-editor-dashboards-done")
                }
            }
        }
        .searchable(text: $query, prompt: "Search Dashboards")
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    private func move(_ id: String, by offset: Int) {
        guard let source = selection.firstIndex(of: id) else { return }
        let destination = source + offset
        guard selection.indices.contains(destination) else { return }
        selection.swapAt(source, destination)
        hapticEvent.trigger(.rigidImpact)
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
            if let order, !isSingleSelection {
                Text("\(order).")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Color.secondary)
                    .frame(minWidth: 20, alignment: .leading)
            }
            PhosphorIcon(
                name: dashboard.iconName,
                size: 19,
                color: TesseraeTheme.accent,
                fallbackSystemName: "rectangle.grid.2x2"
            )
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.name)
                    .font(.body)
                    .foregroundStyle(Color.primary)
                Text(dashboard.kind == .canvas ? "Canvas" : "Grid")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
            Spacer()
            if selected, isSingleSelection {
                Image(systemName: "checkmark")
                    .foregroundStyle(TesseraeTheme.accent)
            } else if !isSingleSelection, !selected {
                Image(systemName: "plus")
                    .foregroundStyle(TesseraeTheme.accent)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

private struct LineupDashboardPickerSection: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let iconName: String?
    let dashboards: [DashboardSummary]
}

private struct LineupDwellEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 300

    let dashboardName: String
    @Binding var minutes: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    Text(dashboardName)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 0)
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .tesseraeModalChromeButtonStyle()
                }

                Text("Time on screen")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                LineupDurationWheel(minutes: $minutes)
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { height in
                if abs(contentHeight - height) > 0.5 { contentHeight = height }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(contentHeight)])
        .accessibilityIdentifier("lineup-duration-sheet")
    }
}

private struct LineupDurationWheel: View {
    @Binding var minutes: Int

    private var hourBinding: Binding<Int> {
        Binding(
            get: { min(minutes / 60, 168) },
            set: { hours in
                if hours == 168 {
                    minutes = 10_080
                } else {
                    minutes = max(1, hours * 60 + min(minutes % 60, 59))
                }
            }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { minutes == 10_080 ? 0 : minutes % 60 },
            set: { minute in
                let hours = min(minutes / 60, 168)
                minutes = hours == 168
                    ? 10_080
                    : max(1, hours * 60 + minute)
            }
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            Picker("Hours", selection: hourBinding) {
                ForEach(0...168, id: \.self) { value in
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
