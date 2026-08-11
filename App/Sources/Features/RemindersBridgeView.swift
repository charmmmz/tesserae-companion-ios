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
                            Button {
                                bridgeModel.toggleList(list.id)
                            } label: {
                                HStack {
                                    Text(list.title)
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    if bridgeModel.selectedListIDs.contains(list.id) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.tint)
                                    } else {
                                        Image(systemName: "circle")
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
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
                        Text("Lists")
                    } footer: {
                        Text("Choose up to 20 lists.")
                    }

                    Section {
                        syncControls
                    } header: {
                        Text("Sync")
                    } footer: {
                        Text(
                            "Tesserae checks selected lists when the app becomes active and after Reminders changes. Unchanged content is not uploaded. Sync Now always uploads."
                        )
                    }
                }

                if let error = bridgeModel.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
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
        .navigationTitle("Apple Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appModel.activeInstance?.id) {
            await bridgeModel.load(using: appModel)
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await bridgeModel.load(using: appModel) }
        }
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

    private var syncStatusSection: some View {
        Section("Sync Status") {
            LabeledContent("Status", value: syncStatus)
            if let status = bridgeModel.sourceStatus {
                LabeledContent("Snapshot", value: status.state.displayName)
                LabeledContent("Last Sync") {
                    Text(status.generatedAt, style: .relative)
                }
                LabeledContent("Expires") {
                    Text(status.expiresAt, style: .relative)
                }
            }
            if let itemCount = bridgeModel.itemCount {
                LabeledContent(
                    "Last Upload",
                    value: String.localizedStringWithFormat(
                        String(localized: "%lld items"),
                        itemCount
                    )
                )
            }
        }
    }

    private var syncStatus: String {
        if bridgeModel.isBusy {
            return String(localized: "Syncing…")
        }
        return bridgeModel.isEnabled
            ? String(localized: "On")
            : String(localized: "Off")
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
            Link(
                "Open iOS Settings",
                destination: URL(string: UIApplication.openSettingsURLString)!
            )
        case .fullAccess:
            Label("Full access allowed", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var syncControls: some View {
        if bridgeModel.isEnabled {
            Button {
                Task { await bridgeModel.syncNow(using: appModel) }
            } label: {
                busyLabel(title: "Sync Now", systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(bridgeModel.isBusy)

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
                busyLabel(title: "Enable and Sync", systemImage: "arrow.up.circle")
            }
            .disabled(bridgeModel.isBusy || bridgeModel.selectedListIDs.isEmpty)

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
    var displayName: String {
        switch self {
        case .fresh: String(localized: "Fresh")
        case .stale: String(localized: "Stale")
        case .expired: String(localized: "Expired")
        }
    }
}
