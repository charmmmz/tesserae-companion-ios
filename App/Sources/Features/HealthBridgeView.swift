import SwiftUI
import TesseraeKit

struct HealthBridgeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(HealthBridgeModel.self) private var bridgeModel
    @Environment(\.openURL) private var openURL
    @State private var deleteConfirmationPresented = false
    @State private var healthAccessInstructionsPresented = false

    var body: some View {
        Form {
            if !appModel.supportsHealthSummaryPersonalData {
                unsupportedSection
            } else if bridgeModel.authorizationState == .unavailable {
                unavailableSection
            } else {
                syncStatusSection
                authorizationSection
                selectionSection
                if bridgeModel.isEnabled || bridgeModel.sourceStatus != nil {
                    syncManagementSection
                }
                retentionSection
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.activeInstance?.id) {
            await bridgeModel.load(using: appModel)
        }
    }

    private var selectionSection: some View {
        Section {
            sectionToggle(
                .activity,
                title: "Activity",
                subtitle: "Steps, distance, Move, Exercise, and Stand"
            )
            sectionToggle(
                .sleep,
                title: "Sleep",
                subtitle: "Bedtime, wake time, duration, and stages"
            )
            sectionToggle(
                .workouts,
                title: "Workouts",
                subtitle: "Type, time, duration, and supported totals"
            )
        } header: {
            Text("Share")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if bridgeModel.isEnabled && bridgeModel.selectedSections.isEmpty {
                    Text("Nothing selected. Stop sync to delete the server snapshot.")
                } else if bridgeModel.hasPendingSelectionChanges {
                    Text("Sync to apply these changes.")
                }
                Text(
                    "Never includes routes, location, heart rate, raw samples, identifiers, device details, notes, or metadata."
                )
            }
        }
    }

    private var authorizationSection: some View {
        Section {
            switch bridgeModel.authorizationState {
            case .unavailable:
                Label("Health is unavailable", systemImage: "heart.slash")
            case .reviewRequired:
                Button {
                    Task { await bridgeModel.requestAccess() }
                } label: {
                    busyLabel(
                        title: "Continue to Health",
                        systemImage: "checkmark.shield"
                    )
                }
                .disabled(
                    bridgeModel.isBusy || bridgeModel.selectedSections.isEmpty
                )
            case .reviewed:
                Label(
                    "Health access reviewed",
                    systemImage: "checkmark.shield.fill"
                )
                .foregroundStyle(.secondary)
                Button {
                    healthAccessInstructionsPresented = true
                } label: {
                    Label(
                        "Manage Health Access",
                        systemImage: "heart.text.clipboard"
                    )
                }
                .alert(
                    "Manage Health Access",
                    isPresented: $healthAccessInstructionsPresented
                ) {
                    Button("Open Health App") {
                        if let url = URL(string: "x-apple-health://") {
                            openURL(url)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(
                        "Open Health, tap your profile picture, then Apps, then Tesserae."
                    )
                }
            }
        } header: {
            Text("Health Access")
        } footer: {
            Text("Permissions remain under your control in Health.")
        }
    }

    private var syncStatusSection: some View {
        Section {
            PersonalDataSyncStatusView(
                state: syncState,
                sourceStatus: bridgeModel.sourceStatus,
                summary: healthSyncSummary,
                feedbackMessage: syncFeedbackMessage
            )

            if let action = primarySyncAction {
                Button {
                    Task { await action.perform() }
                } label: {
                    Label(action.title, systemImage: action.systemImage)
                }
            }
        } header: {
            Text("Sync Status")
        } footer: {
            Text("Checks when the app becomes active. Background updates are best effort.")
        }
    }

    private var syncState: PersonalDataSyncState {
        .health(
            isSupported: appModel.supportsHealthSummaryPersonalData,
            model: bridgeModel
        )
    }

    private var syncFeedbackMessage: String? {
        if let errorMessage = bridgeModel.errorMessage {
            if bridgeModel.sourceStatus != nil {
                return String(
                    localized: "The latest refresh did not complete. The existing server snapshot is still available."
                )
            }
            return errorMessage
        }
        switch syncState {
        case .off, .needsAccess:
            return bridgeModel.confirmationMessage
        default:
            return nil
        }
    }

    private var healthSyncSummary: String? {
        guard bridgeModel.sourceStatus != nil else { return nil }
        var values: [String] = []
        if let activityDayCount = bridgeModel.activityDayCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld activity days"),
                    activityDayCount
                )
            )
        }
        if let sleepNightCount = bridgeModel.sleepNightCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld sleep nights"),
                    sleepNightCount
                )
            )
        }
        if let workoutCount = bridgeModel.workoutCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld workouts"),
                    workoutCount
                )
            )
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var primarySyncAction: PersonalDataSyncAction? {
        guard !bridgeModel.isBusy else { return nil }
        if bridgeModel.isEnabled {
            guard
                !bridgeModel.selectedSections.isEmpty,
                bridgeModel.authorizationState == .reviewed
            else { return nil }
            return PersonalDataSyncAction(
                title: bridgeModel.hasPendingSelectionChanges
                    ? "Apply Changes and Sync"
                    : "Sync Now",
                systemImage: "arrow.triangle.2.circlepath",
                perform: {
                    await bridgeModel.syncNow(using: appModel)
                }
            )
        }
        guard
            !bridgeModel.selectedSections.isEmpty,
            bridgeModel.authorizationState == .reviewed
        else { return nil }
        return PersonalDataSyncAction(
            title: "Enable and Sync",
            systemImage: "arrow.up.circle",
            perform: {
                await bridgeModel.enableAndSync(using: appModel)
            }
        )
    }

    private var retentionSection: some View {
        Section {
            Text(
                "The server keeps one expiring snapshot. Rendered values may remain in History or on a display until replaced."
            )
        } header: {
            Text("Privacy")
        }
    }

    private var syncManagementSection: some View {
        Section {
            if bridgeModel.isEnabled {
                deleteSnapshotButton(
                    title: "Stop Sync and Delete Snapshot",
                    systemImage: "trash"
                )
            } else {
                if bridgeModel.sourceStatus != nil {
                    deleteSnapshotButton(
                        title: "Delete Existing Snapshot",
                        systemImage: "trash"
                    )
                }
            }
        } header: {
            Text("Manage Sync")
        }
    }

    private var unsupportedSection: some View {
        Section {
            Label(
                "The connected server does not support Health summaries.",
                systemImage: "server.rack"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var unavailableSection: some View {
        Section {
            Label(
                "Health data is unavailable. Use a physical iPhone to configure access.",
                systemImage: "heart.slash"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func sectionToggle(
        _ section: HealthSummarySection,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey
    ) -> some View {
        Toggle(
            isOn: Binding(
                get: { bridgeModel.selectedSections.contains(section) },
                set: { _ in bridgeModel.toggleSection(section) }
            )
        ) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deleteSnapshotButton(
        title: LocalizedStringKey,
        systemImage: String
    ) -> some View {
        Button(role: .destructive) {
            deleteConfirmationPresented = true
        } label: {
            busyLabel(
                title: title,
                systemImage: systemImage,
                showsProgress: false
            )
        }
        .disabled(bridgeModel.isBusy)
        .confirmationDialog(
            "Stop Health Sync?",
            isPresented: $deleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Stop Sync and Delete Snapshot", role: .destructive) {
                Task {
                    await bridgeModel.disableAndDelete(using: appModel)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This deletes the latest server snapshot. Rendered images remain until replaced or expired."
            )
        }
    }

    private func busyLabel(
        title: LocalizedStringKey,
        systemImage: String,
        showsProgress: Bool = true
    ) -> some View {
        HStack(spacing: 8) {
            Group {
                if showsProgress && bridgeModel.isBusy {
                    ProgressView()
                } else {
                    Image(systemName: systemImage)
                }
            }
            .frame(width: 28)
            Text(title)
        }
    }
}

struct PersonalDataSyncAction {
    let title: LocalizedStringKey
    let systemImage: String
    let perform: @MainActor () async -> Void
}

enum PersonalDataSyncState: Equatable {
    case unsupported
    case unavailable
    case needsAccess
    case off
    case syncing
    case changesPending
    case waitingForFirstSync
    case fresh
    case stale
    case expired
    case failed

    @MainActor
    static func reminders(
        isSupported: Bool,
        model: RemindersBridgeModel
    ) -> Self {
        resolve(
            isSupported: isSupported,
            isAvailable: true,
            isBusy: model.isBusy,
            hasError: model.errorMessage != nil,
            needsAccess: model.authorizationState == .denied
                || model.isEnabled
                    && model.authorizationState != .fullAccess,
            isEnabled: model.isEnabled,
            hasPendingChanges: model.hasPendingSelectionChanges,
            freshness: model.sourceStatus?.state
        )
    }

    @MainActor
    static func health(
        isSupported: Bool,
        model: HealthBridgeModel
    ) -> Self {
        resolve(
            isSupported: isSupported,
            isAvailable: model.authorizationState != .unavailable,
            isBusy: model.isBusy,
            hasError: model.errorMessage != nil,
            needsAccess: model.isEnabled
                && model.authorizationState != .reviewed,
            isEnabled: model.isEnabled,
            hasPendingChanges: model.hasPendingSelectionChanges,
            freshness: model.sourceStatus?.state
        )
    }

    static func resolve(
        isSupported: Bool,
        isAvailable: Bool,
        isBusy: Bool,
        hasError: Bool,
        needsAccess: Bool,
        isEnabled: Bool,
        hasPendingChanges: Bool,
        freshness: PersonalDataFreshness?
    ) -> Self {
        guard isSupported else { return .unsupported }
        guard isAvailable else { return .unavailable }
        if isBusy { return .syncing }
        if needsAccess { return .needsAccess }
        guard isEnabled else { return .off }
        if hasPendingChanges { return .changesPending }
        if let freshness {
            switch freshness {
            case .fresh: return .fresh
            case .stale: return .stale
            case .expired: return .expired
            }
        }
        return hasError ? .failed : .waitingForFirstSync
    }

    var settingsLabel: String {
        switch self {
        case .unsupported: String(localized: "Server update required")
        case .unavailable: String(localized: "Unavailable")
        case .needsAccess: String(localized: "Needs Access")
        case .off: String(localized: "Off")
        case .syncing: String(localized: "Syncing…")
        case .changesPending: String(localized: "Changes Pending")
        case .waitingForFirstSync: String(localized: "Not Synced")
        case .fresh: String(localized: "Synced")
        case .stale: String(localized: "Needs Refresh")
        case .expired: String(localized: "Expired")
        case .failed: String(localized: "Sync Failed")
        }
    }

    var title: String {
        switch self {
        case .unsupported: String(localized: "Server update required")
        case .unavailable: String(localized: "Health is unavailable")
        case .needsAccess: String(localized: "Access required")
        case .off: String(localized: "Sync is off")
        case .syncing: String(localized: "Syncing…")
        case .changesPending: String(localized: "Changes ready to apply")
        case .waitingForFirstSync: String(localized: "Waiting for first sync")
        case .fresh: String(localized: "Up to date")
        case .stale: String(localized: "Needs refresh")
        case .expired: String(localized: "Snapshot expired")
        case .failed: String(localized: "Sync failed")
        }
    }

    var message: String {
        switch self {
        case .unsupported:
            String(localized: "Update the connected Tesserae server to use this source.")
        case .unavailable:
            String(localized: "This source is not available on this device.")
        case .needsAccess:
            String(localized: "Review access below to continue syncing.")
        case .off:
            String(localized: "No new data is being sent to this Tesserae server.")
        case .syncing:
            String(localized: "Preparing and sending the latest selected data.")
        case .changesPending:
            String(localized: "Sync to update the server snapshot with your current selection.")
        case .waitingForFirstSync:
            String(localized: "Complete the first sync to create a server snapshot.")
        case .fresh:
            String(localized: "The latest server snapshot is ready.")
        case .stale:
            String(localized: "Sync now to refresh the server snapshot.")
        case .expired:
            String(localized: "Widgets can no longer use this snapshot.")
        case .failed:
            String(localized: "The latest sync did not complete.")
        }
    }

    var symbolName: String {
        switch self {
        case .unsupported: "server.rack"
        case .unavailable: "heart.slash.fill"
        case .needsAccess: "exclamationmark.shield.fill"
        case .off: "pause.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .changesPending: "arrow.up.circle.fill"
        case .waitingForFirstSync: "clock.fill"
        case .fresh: "checkmark.circle.fill"
        case .stale: "exclamationmark.circle.fill"
        case .expired: "xmark.octagon.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .fresh: .green
        case .needsAccess, .changesPending, .stale: .orange
        case .expired, .failed: .red
        case .syncing: TesseraeTheme.accent
        case .unsupported, .unavailable, .off, .waitingForFirstSync: .secondary
        }
    }

    var showsExpiration: Bool {
        switch self {
        case .stale, .expired: true
        default: false
        }
    }
}

/// Native settings rows shared by the Health and Reminders pages.
struct PersonalDataSyncStatusView: View {
    let state: PersonalDataSyncState
    let sourceStatus: PersonalDataSourceStatus?
    let summary: String?
    let feedbackMessage: String?

    var body: some View {
        Group {
            Label {
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                    if let detailMessage {
                        Text(detailMessage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } icon: {
                Image(systemName: state.symbolName)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(state.tint)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("personal-data-sync-status")

            if let sourceStatus {
                LabeledContent {
                    Text(sourceStatus.generatedAt, style: .relative)
                        .foregroundStyle(.secondary)
                } label: {
                    Label("Last synced", systemImage: "clock")
                }

                if state.showsExpiration {
                    LabeledContent {
                        expirationText(sourceStatus)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("Expires", systemImage: "hourglass")
                    }
                }
            }

            if let summary {
                LabeledContent {
                    Text(summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label("Included", systemImage: "chart.bar.doc.horizontal")
                }
            }
        }
    }

    private var detailMessage: String? {
        if let feedbackMessage {
            return feedbackMessage
        }
        return state == .fresh ? nil : state.message
    }

    @ViewBuilder
    private func expirationText(
        _ status: PersonalDataSourceStatus
    ) -> some View {
        if status.expiresAt <= .now {
            Text("Expired \(status.expiresAt, style: .relative)")
        } else {
            Text("Expires \(status.expiresAt, style: .relative)")
        }
    }
}
