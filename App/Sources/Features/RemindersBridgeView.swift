import SwiftUI
import TesseraeKit
import UIKit

struct RemindersBridgeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var bridgeModel = RemindersBridgeModel()
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
                        "Only incomplete items from the selected list are read. Notes, URLs, alarms, locations, and other lists are never included."
                    )
                }

                if bridgeModel.authorizationState == .fullAccess {
                    Section("Source") {
                        Picker(
                            "List",
                            selection: Binding(
                                get: { bridgeModel.selectedListID ?? "" },
                                set: { bridgeModel.chooseList($0) }
                            )
                        ) {
                            Text("Choose a List").tag("")
                            ForEach(bridgeModel.lists) { list in
                                Text(list.title).tag(list.id)
                            }
                        }
                        .disabled(bridgeModel.isBusy)
                    }

                    Section {
                        syncControls
                    } header: {
                        Text("Sync")
                    } footer: {
                        Text(
                            "This first slice syncs only when you tap the button. Background best-effort refresh will be added separately."
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
        .navigationTitle("Grocery Reminders")
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
                "The selected list stays on this iPhone. Tesserae immediately deletes its latest raw snapshot. Existing rendered History thumbnails follow the normal render-cache lifetime."
            )
        }
    }

    @ViewBuilder
    private var capabilityContent: some View {
        if appModel.supportsRemindersPersonalData {
            LabeledContent("Reminders Bridge", value: "Available")
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
                "Reminders access is off. Enable full access in iOS Settings to choose a list.",
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
            .disabled(bridgeModel.isBusy || bridgeModel.selectedListID == nil)

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
            .disabled(bridgeModel.isBusy || bridgeModel.selectedListID == nil)

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
