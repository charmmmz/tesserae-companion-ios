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
            Section {
                capabilityContent
            } header: {
                Text("Tesserae Server")
            } footer: {
                Text(
                    "The phone remains authoritative. Tesserae stores only the latest expiring snapshot and returns freshness metadata, not reminder contents."
                )
            }

            if appModel.supportsRemindersPersonalData {
                Section {
                    authorizationContent
                } header: {
                    Text("Reminders Access")
                } footer: {
                    Text(
                        "Only incomplete items from lists you select are read. Notes, URLs, alarms, locations, and unselected lists are never included."
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
                        Text(
                            "Choose up to 20 lists. Each upload replaces the complete published set; syncing no selections keeps the enabled source fresh but makes its widgets unavailable."
                        )
                    }

                    Section {
                        syncControls
                    } header: {
                        Text("Sync")
                    } footer: {
                        Text(
                            "While Tesserae is running, EventKit changes trigger a debounced refresh of the selected lists. iOS does not guarantee background wakeups, so Sync Now remains available."
                        )
                    }
                }

                if bridgeModel.confirmationMessage != nil
                    || bridgeModel.errorMessage != nil
                {
                    Section("Result") {
                        if let confirmation = bridgeModel.confirmationMessage {
                            Label(confirmation, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        if let error = bridgeModel.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
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
                "The selected lists stay on this iPhone. Tesserae immediately deletes its latest raw snapshot. Existing rendered History thumbnails follow the normal render-cache lifetime."
            )
        }
    }

    @ViewBuilder
    private var capabilityContent: some View {
        if appModel.supportsRemindersPersonalData {
            LabeledContent("Reminders Bridge", value: "Available")
            LabeledContent("Server Source", value: "Apple Reminders")
            if let status = bridgeModel.sourceStatus {
                LabeledContent("Snapshot", value: status.state.displayName)
                LabeledContent("Generated") {
                    Text(status.generatedAt, style: .relative)
                }
                LabeledContent("Expires") {
                    Text(status.expiresAt, style: .relative)
                }
            } else {
                LabeledContent("Snapshot", value: "Not uploaded")
            }
        } else {
            Label(
                "The connected server does not support the Reminders bridge yet.",
                systemImage: "server.rack"
            )
            .foregroundStyle(.secondary)
        }
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
                Label("Stop Sync and Delete Snapshot", systemImage: "trash")
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
                    Label("Delete Existing Snapshot", systemImage: "trash")
                }
                .disabled(bridgeModel.isBusy)
            }
        }

        if let itemCount = bridgeModel.itemCount {
            LabeledContent("Last Upload", value: "\(itemCount) items")
        }
        LabeledContent("Selected", value: "\(bridgeModel.selectedListCount) lists")
    }

    private func busyLabel(title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 8) {
            if bridgeModel.isBusy {
                ProgressView()
            } else {
                Image(systemName: systemImage)
            }
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
