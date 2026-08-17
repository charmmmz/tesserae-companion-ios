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
                introductionSection
                selectionSection
                requestedDataSection
                excludedDataSection
                authorizationSection
                if bridgeModel.isEnabled || bridgeModel.sourceStatus != nil {
                    syncStatusSection
                }
                retentionSection
                syncControlsSection
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
            "Stop Apple Health Sync?",
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
                "Tesserae deletes the latest raw Health snapshot now. Existing History thumbnails expire normally, and an e-ink display keeps its current image until replaced."
            )
        }
    }

    private var introductionSection: some View {
        Section {
            Text(
                "Choose which seven-day Apple Health summaries this iPhone may read and send directly to your paired Tesserae Server. Tesserae requests read access only and never writes to Apple Health."
            )
        } header: {
            Text("On-device summary")
        }
    }

    private var selectionSection: some View {
        Section {
            sectionToggle(
                .activity,
                title: "Activity",
                subtitle: "Daily steps, distance, Move, Exercise, and Stand"
            )
            sectionToggle(
                .sleep,
                title: "Sleep",
                subtitle: "One primary sleep period per wake date"
            )
            sectionToggle(
                .workouts,
                title: "Workouts",
                subtitle: "Workout timing, type, duration, and supported totals"
            )
        } header: {
            Text("Summaries to share")
        } footer: {
            if bridgeModel.isEnabled && bridgeModel.selectedSections.isEmpty {
                Text(
                    "No summaries are selected. Stop sync below to delete the server snapshot."
                )
            } else if bridgeModel.hasPendingSelectionChanges {
                Text("Your selection changes take effect after Sync Now.")
            } else {
                Text(
                    "Selections are stored separately for this Tesserae Server. All choices default to off."
                )
            }
        }
    }

    private var requestedDataSection: some View {
        Section {
            if bridgeModel.selectedSections.isEmpty {
                Text("Choose a summary above to see every Apple Health read type.")
                    .foregroundStyle(.secondary)
            }
            if bridgeModel.selectedSections.contains(.activity) {
                disclosureGroup(
                    title: "Activity read types",
                    items: [
                        "Activity Summary — Move mode, value and goal; Exercise minutes and goal; Stand hours and goal",
                        "Step Count — daily total",
                        "Walking + Running Distance — daily metres"
                    ]
                )
            }
            if bridgeModel.selectedSections.contains(.sleep) {
                disclosureGroup(
                    title: "Sleep read types",
                    items: [
                        "Sleep Analysis — primary period start and end; in-bed, asleep, awake, Core, Deep, REM, and unspecified totals"
                    ]
                )
            }
            if bridgeModel.selectedSections.contains(.workouts) {
                disclosureGroup(
                    title: "Workout read types",
                    items: [
                        "Workouts — activity type, start and end, active duration, and multi-activity segment timing",
                        "Active Energy — workout and segment kilocalories",
                        "Walking + Running, Cycling, Swimming, and Wheelchair Distance — separate workout and segment metres",
                        "Flights Climbed — workout and segment totals",
                        "Swimming Stroke Count — workout and segment totals"
                    ]
                )
            }
        } header: {
            Text("Requested data")
        } footer: {
            Text(
                "Apple shows the final per-type read controls next. Apple does not tell apps which individual read types you denied. Missing or unreadable values remain empty, never false zeroes."
            )
        }
    }

    private var excludedDataSection: some View {
        Section {
            Label("Routes and location", systemImage: "location.slash")
            Label("Heart rate and heart-rate samples", systemImage: "heart.slash")
            Label(
                "Raw samples, HealthKit identifiers, device and source details",
                systemImage: "eye.slash"
            )
            Label(
                "Workout events, titles, notes, and free-form metadata",
                systemImage: "doc.badge.ellipsis"
            )
        } header: {
            Text("Never shared")
        }
    }

    private var authorizationSection: some View {
        Section {
            switch bridgeModel.authorizationState {
            case .unavailable:
                Label("Apple Health is unavailable", systemImage: "heart.slash")
            case .reviewRequired:
                Button {
                    Task { await bridgeModel.requestAccess() }
                } label: {
                    busyLabel(
                        title: "Continue to Apple Health",
                        systemImage: "checkmark.shield"
                    )
                }
                .disabled(
                    bridgeModel.isBusy || bridgeModel.selectedSections.isEmpty
                )
            case .reviewed:
                Label(
                    "Apple Health access reviewed for the selected summaries",
                    systemImage: "checkmark.shield.fill"
                )
                .foregroundStyle(.secondary)
                Button("Review Apple Health Access Again") {
                    Task { await bridgeModel.requestAccess() }
                }
                .disabled(bridgeModel.isBusy)
            }
        } header: {
            Text("Apple authorization")
        } footer: {
            Text(
                "Changing a Tesserae selection may require reviewing additional Apple Health types. Health permissions remain under your control in Apple Health and iOS Settings."
            )
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
                "The server keeps only the latest expiring raw snapshot. Health values rendered on a Dashboard may remain temporarily visible in normal History thumbnails and on an e-ink display."
            )
            Text(
                "Stopping sync deletes the raw server snapshot, but it cannot retroactively erase rendered images. Display another Dashboard to replace health values already shown on a panel."
            )
        } header: {
            Text("Server and rendered copies")
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
            Text(
                "Tesserae checks for changes when the app becomes active. Sync Now always uploads. Background delivery is best effort and is not promised by this version."
            )
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
                "The connected server does not support Apple Health summaries yet.",
                systemImage: "server.rack"
            )
            .foregroundStyle(.secondary)
        }
    }

    private var unavailableSection: some View {
        Section {
            Label(
                "Apple Health data is not available on this device. Use a physical iPhone to configure Health access.",
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
