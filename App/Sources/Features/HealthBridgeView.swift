import SwiftUI
import TesseraeKit
import UIKit

struct HealthBridgeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(HealthBridgeModel.self) private var bridgeModel
    @State private var deleteConfirmationPresented = false

    var body: some View {
        Form {
            if !appModel.supportsHealthSummaryPersonalData {
                unsupportedSection
            } else if bridgeModel.authorizationState == .unavailable {
                unavailableSection
            } else {
                selectionSection
                if !bridgeModel.selectedSections.isEmpty {
                    requestedDataSection
                    authorizationSection
                }
                if bridgeModel.isEnabled || bridgeModel.sourceStatus != nil {
                    syncStatusSection
                }
                retentionSection
                if !bridgeModel.selectedSections.isEmpty
                    || bridgeModel.isEnabled
                    || bridgeModel.sourceStatus != nil
                {
                    syncControlsSection
                }
                feedbackSections
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Health")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.activeInstance?.id) {
            await bridgeModel.load(using: appModel)
        }
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
            if bridgeModel.isEnabled && bridgeModel.selectedSections.isEmpty {
                Text("Nothing selected. Stop sync to delete the server snapshot.")
            } else if bridgeModel.hasPendingSelectionChanges {
                Text("Sync to apply these changes.")
            }
        }
    }

    private var requestedDataSection: some View {
        Section {
            if bridgeModel.selectedSections.contains(.activity) {
                disclosureGroup(
                    title: "Activity data",
                    items: [
                        "Move, Exercise, and Stand values and goals",
                        "Daily steps and walking + running distance"
                    ]
                )
            }
            if bridgeModel.selectedSections.contains(.sleep) {
                disclosureGroup(
                    title: "Sleep data",
                    items: [
                        "Start, end, in-bed, asleep, awake, Core, Deep, REM, and unspecified totals"
                    ]
                )
            }
            if bridgeModel.selectedSections.contains(.workouts) {
                disclosureGroup(
                    title: "Workout data",
                    items: [
                        "Activity type, start, end, duration, and segment timing",
                        "Energy, supported distances, flights, and swimming strokes"
                    ]
                )
            }
        } header: {
            Text("Data Access")
        } footer: {
            Text(
                "Never includes routes, location, heart rate, raw samples, identifiers, device details, notes, or metadata."
            )
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
                Button("Review Health Access") {
                    Task { await bridgeModel.requestAccess() }
                }
                .disabled(bridgeModel.isBusy)
            }
        } header: {
            Text("Health Access")
        } footer: {
            Text("Permissions remain under your control in Health and iOS Settings.")
        }
    }

    private var syncStatusSection: some View {
        Section("Sync Status") {
            LabeledContent(
                "Status",
                value: bridgeModel.isEnabled
                    ? String(localized: "On")
                    : String(localized: "Off")
            )
            if let status = bridgeModel.sourceStatus {
                LabeledContent("Snapshot", value: status.state.healthDisplayName)
                LabeledContent("Last Sync") {
                    Text(status.generatedAt, style: .relative)
                }
                LabeledContent("Expires") {
                    Text(status.expiresAt, style: .relative)
                }
            }
            if let activityDayCount = bridgeModel.activityDayCount {
                LabeledContent("Activity", value: "\(activityDayCount) days")
            }
            if let sleepNightCount = bridgeModel.sleepNightCount {
                LabeledContent("Sleep", value: "\(sleepNightCount) nights")
            }
            if let workoutCount = bridgeModel.workoutCount {
                LabeledContent("Workouts", value: "\(workoutCount)")
            }
        }
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

    private var syncControlsSection: some View {
        Section {
            if bridgeModel.isEnabled {
                if !bridgeModel.selectedSections.isEmpty {
                    Button {
                        Task { await bridgeModel.syncNow(using: appModel) }
                    } label: {
                        busyLabel(
                            title: bridgeModel.hasPendingSelectionChanges
                                ? "Apply Changes and Sync"
                                : "Sync Now",
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .disabled(
                        bridgeModel.isBusy
                            || bridgeModel.authorizationState != .reviewed
                    )
                }
                Button(role: .destructive) {
                    deleteConfirmationPresented = true
                } label: {
                    busyLabel(
                        title: "Stop Sync and Delete Snapshot",
                        systemImage: "trash",
                        showsProgress: false
                    )
                }
                .disabled(bridgeModel.isBusy)
            } else {
                Button {
                    Task { await bridgeModel.enableAndSync(using: appModel) }
                } label: {
                    busyLabel(
                        title: "Enable and Sync",
                        systemImage: "arrow.up.circle"
                    )
                }
                .disabled(
                    bridgeModel.isBusy
                        || bridgeModel.selectedSections.isEmpty
                        || bridgeModel.authorizationState != .reviewed
                )

                if bridgeModel.sourceStatus != nil {
                    Button(role: .destructive) {
                        deleteConfirmationPresented = true
                    } label: {
                        busyLabel(
                            title: "Delete Existing Snapshot",
                            systemImage: "trash",
                            showsProgress: false
                        )
                    }
                    .disabled(bridgeModel.isBusy)
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text("Checks when the app becomes active. Background updates are best effort.")
        }
    }

    @ViewBuilder
    private var feedbackSections: some View {
        if let confirmation = bridgeModel.confirmationMessage {
            Section {
                Label(confirmation, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        if let error = bridgeModel.errorMessage {
            Section {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
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

    private func disclosureGroup(
        title: LocalizedStringKey,
        items: [LocalizedStringKey]
    ) -> some View {
        DisclosureGroup(title) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 2)
            }
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

private extension PersonalDataFreshness {
    var healthDisplayName: String {
        switch self {
        case .fresh: String(localized: "Fresh")
        case .stale: String(localized: "Stale")
        case .expired: String(localized: "Expired")
        }
    }
}
