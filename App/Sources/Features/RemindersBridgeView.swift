import SwiftUI
import TesseraeKit
import UIKit

struct RemindersBridgeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(RemindersBridgeModel.self) private var bridgeModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var deleteConfirmationPresented = false

    var body: some View {
        Form {
            if appModel.supportsRemindersPersonalData {
                syncStatusSection

                Section {
                    authorizationContent
                    Link(
                        destination: URL(string: UIApplication.openSettingsURLString)!
                    ) {
                        Label("Open in iOS Settings", systemImage: "gearshape")
                    }
                } header: {
                    Text("Reminders Access")
                } footer: {
                    Text(
                        "Only incomplete reminders from selected lists are shared. Notes, URLs, alarms, and locations stay on this iPhone."
                    )
                }

                if bridgeModel.authorizationState == .fullAccess {
                    Section {
                        ForEach(bridgeModel.lists) { list in
                            Toggle(
                                isOn: Binding(
                                    get: {
                                        bridgeModel.selectedListIDs.contains(list.id)
                                    },
                                    set: { _ in
                                        bridgeModel.toggleList(list.id)
                                    }
                                )
                            ) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.title)
                                    if let itemCount = bridgeModel.listItemCounts[list.id] {
                                        Text(
                                            String.localizedStringWithFormat(
                                                String(localized: "%lld items"),
                                                itemCount
                                            )
                                        )
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .disabled(bridgeModel.isBusy)
                        }
                        ForEach(
                            bridgeModel.unavailableSelectedLists
                        ) { list in
                            Button {
                                bridgeModel.removeUnavailableList(list.id)
                            } label: {
                                HStack {
                                    Label(
                                        "\(list.title) is no longer available",
                                        systemImage: "exclamationmark.triangle.fill"
                                    )
                                    Spacer()
                                    Text("Remove")
                                }
                                .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .disabled(bridgeModel.isBusy)
                        }
                    } header: {
                        Text("Share")
                    } footer: {
                        Text("Choose up to 20 lists.")
                    }
                }

                if bridgeModel.isEnabled || bridgeModel.sourceStatus != nil {
                    syncManagementSection
                }
            } else {
                Section {
                    Label(
                        "The connected server does not support Apple Reminders yet.",
                        systemImage: "server.rack"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.activeInstance?.id) {
            await bridgeModel.load(using: appModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await bridgeModel.load(using: appModel) }
        }
    }

    private var syncStatusSection: some View {
        Section {
            PersonalDataSyncStatusView(
                state: syncState,
                sourceStatus: bridgeModel.sourceStatus,
                summary: remindersSyncSummary,
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
            Text(
                "Tesserae checks selected lists when the app becomes active and after Reminders changes. Unchanged content is not uploaded. Sync Now always uploads."
            )
        }
    }

    private var syncState: PersonalDataSyncState {
        .reminders(
            isSupported: appModel.supportsRemindersPersonalData,
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

    private var remindersSyncSummary: String? {
        guard bridgeModel.sourceStatus != nil else { return nil }
        var values: [String] = []
        if let includedListCount = bridgeModel.includedListCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld lists"),
                    includedListCount
                )
            )
        }
        if let itemCount = bridgeModel.itemCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld incomplete reminders"),
                    itemCount
                )
            )
        }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var primarySyncAction: PersonalDataSyncAction? {
        guard
            !bridgeModel.isBusy,
            bridgeModel.authorizationState == .fullAccess
        else { return nil }
        if bridgeModel.isEnabled {
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
        guard !bridgeModel.selectedListIDs.isEmpty else { return nil }
        return PersonalDataSyncAction(
            title: "Enable and Sync",
            systemImage: "arrow.up.circle",
            perform: {
                await bridgeModel.enableAndSync(using: appModel)
            }
        )
    }

    @ViewBuilder
    private var authorizationContent: some View {
        switch bridgeModel.authorizationState {
        case .notDetermined:
            Button {
                Task { await bridgeModel.requestAccess() }
            } label: {
                if bridgeModel.isBusy {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Requesting Access…")
                    }
                } else {
                    Label("Allow Reminders Access", systemImage: "checklist")
                }
            }
            .disabled(bridgeModel.isBusy)
        case .denied:
            Label(
                "Reminders access is off. Enable full access in iOS Settings to choose lists.",
                systemImage: "hand.raised.fill"
            )
            .foregroundStyle(.secondary)
        case .fullAccess:
            Label("Full access allowed", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var syncManagementSection: some View {
        Section {
            syncManagementControls
        } header: {
            Text("Manage Sync")
        }
    }

    @ViewBuilder
    private var syncManagementControls: some View {
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
            "Stop Reminders Sync?",
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
                "Selected lists stay on this iPhone. Tesserae deletes the latest snapshot now; rendered History thumbnails expire normally."
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
