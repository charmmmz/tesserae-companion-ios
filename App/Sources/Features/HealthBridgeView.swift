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
                syncStatusSection
                authorizationSection
                selectionSection
                if !bridgeModel.selectedSections.isEmpty
                    || bridgeModel.isEnabled
                    || bridgeModel.sourceStatus != nil
                {
                    syncControlsSection
                }
                retentionSection
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
                Link(
                    "Open in iOS Settings",
                    destination: URL(string: UIApplication.openSettingsURLString)!
                )
            }
        } header: {
            Text("Health Access")
        } footer: {
            Text("Permissions remain under your control in Health and iOS Settings.")
        }
    }

    private var syncStatusSection: some View {
        Section("Sync Status") {
            PersonalDataSyncStatusView(
                sourceStatus: bridgeModel.sourceStatus,
                counts: healthSyncCounts
            )
        }
    }

    private var healthSyncCounts: [String] {
        var values: [String] = []
        if let activityDayCount = bridgeModel.activityDayCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld days"),
                    activityDayCount
                )
            )
        }
        if let sleepNightCount = bridgeModel.sleepNightCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld nights"),
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
        return values
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
                deleteSnapshotButton(
                    title: "Stop Sync and Delete Snapshot",
                    systemImage: "trash"
                )
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
                    deleteSnapshotButton(
                        title: "Delete Existing Snapshot",
                        systemImage: "trash"
                    )
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

/// Shared Sync Status visual used by the Health and Reminders settings pages.
/// Colour and shape carry the state; text stays for accessibility and clarity.
struct PersonalDataSyncStatusView: View {
    let sourceStatus: PersonalDataSourceStatus?
    let counts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let sourceStatus {
                freshnessAxis
                freshnessBar(sourceStatus)
                metaRow(sourceStatus)
            }
            if !counts.isEmpty {
                countPills
            }
        }
    }

    private func freshnessBar(
        _ status: PersonalDataSourceStatus
    ) -> some View {
        let now = Date()
        let total = status.expiresAt.timeIntervalSince(status.generatedAt)
        let fraction = total > 0
            ? min(1, max(0, now.timeIntervalSince(status.generatedAt) / total))
            : 1
        let staleFraction = total > 0
            ? min(
                1,
                max(
                    0,
                    status.staleAt.timeIntervalSince(status.generatedAt) / total
                )
            )
            : 1
        return GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(freshnessColor)
                    .frame(width: max(4, width * fraction))
                Rectangle()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: 1)
                    .offset(x: width * staleFraction - 0.5)
            }
        }
        .frame(height: 6)
    }

    private var freshnessColor: Color {
        guard let sourceStatus else { return Color.secondary }
        switch sourceStatus.state {
        case .fresh: return .green
        case .stale: return .orange
        case .expired: return .red
        }
    }

    private var freshnessAxis: some View {
        HStack {
            axisLabel(title: String(localized: "Fresh"), color: .green)
            Spacer()
            axisLabel(title: String(localized: "Stale"), color: .orange)
            Spacer()
            axisLabel(title: String(localized: "Expired"), color: .red)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func axisLabel(
        title: String,
        color: Color
    ) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(title)
        }
    }

    private func metaRow(
        _ status: PersonalDataSourceStatus
    ) -> some View {
        HStack {
            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .accessibilityLabel(Text("Last Sync"))
                Text(status.generatedAt, style: .relative)
            }
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "hourglass")
                    .accessibilityLabel(Text("Expires"))
                Text(status.expiresAt, style: .relative)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var countPills: some View {
        HStack(spacing: 6) {
            ForEach(counts, id: \.self) { label in
                Text(label)
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.055), in: Capsule())
            }
        }
    }
}
